import Foundation

/// Turns what the user typed in the address bar into a page to load.
enum BrowserAddress {
    static let searchTemplate = "https://www.bing.com/search?q="

    /// Web addresses are loaded as typed (adding a scheme when missing); anything else becomes a search.
    /// Returns nil for empty input and for non-web schemes such as `file:` or `javascript:`.
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            if let scheme = explicitScheme(text) {
                guard ["http", "https"].contains(scheme), let url = URL(string: text), url.host?.isEmpty == false else { return nil }
                return url
            }
            if looksLikeHost(text) {
                let isLocal = text.lowercased().hasPrefix("localhost") || isIPv4Prefix(text)
                if let url = URL(string: (isLocal ? "http://" : "https://") + text), url.host?.isEmpty == false { return url }
            }
        }
        return search(text)
    }

    static func search(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/:;")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchTemplate + encoded)
    }

    /// The address bar shows nothing for the built-in start page.
    static func display(_ url: URL?) -> String {
        guard let url, url.scheme != "about" else { return "" }
        return url.absoluteString
    }

    /// What the address bar shows while idle: just the site, like Safari.
    static func compact(_ url: URL?) -> String {
        guard let url, url.scheme != "about" else { return "" }
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host, !host.isEmpty else {
            return url.absoluteString
        }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isSecure(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    private static func explicitScheme(_ text: String) -> String? {
        guard let range = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(//)?", options: .regularExpression) else { return nil }
        let prefix = text[range]
        // "host:8080" is a host with a port, not a scheme.
        if !prefix.hasSuffix("//"), text[range.upperBound...].first?.isNumber == true { return nil }
        return prefix.prefix { $0 != ":" }.lowercased()
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let authority = text.prefix { !"/?#".contains($0) }
        let pattern = "^(localhost|[\\w-]+(\\.[\\w-]+)+|\\[[0-9A-Fa-f:]+\\])(:[0-9]{1,5})?$"
        return authority.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isIPv4Prefix(_ text: String) -> Bool {
        text.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}([:/?#]|$)", options: .regularExpression) != nil
    }
}

enum BrowserZoom {
    static let steps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let `default` = 1.0

    static func zoomedIn(_ value: Double) -> Double { steps.first { $0 > value + 0.001 } ?? steps[steps.count - 1] }
    static func zoomedOut(_ value: Double) -> Double { steps.last { $0 < value - 0.001 } ?? steps[0] }
}

/// The identity the browser presents to websites.
enum BrowserUserAgent: Equatable {
    case iPhone, iPad, safari, chrome
    case custom(String)

    static let presets: [BrowserUserAgent] = [.iPhone, .iPad, .safari, .chrome]
    static let `default` = BrowserUserAgent.iPhone
    static let customLimit = 512
    private static let storageKey = "browser.userAgent"
    private static let legacyMobileKey = "browser.mobileSites"

    var title: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .safari: return "Mac Safari"
        case .chrome: return "Mac Chrome"
        case .custom: return "自定义"
        }
    }

    /// nil keeps WebKit's own Safari identity.
    var string: String? {
        switch self {
        case .iPhone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .iPad:
            return "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .safari:
            return nil
        case .chrome:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        case .custom(let value):
            return value
        }
    }

    var usesMobileContent: Bool { self == .iPhone }

    /// A custom identity must be one printable line.
    static func validatedCustom(_ text: String) -> BrowserUserAgent? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= customLimit,
              !value.contains(where: { $0.isNewline || $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } })
        else { return nil }
        return .custom(value)
    }

    static func load(from defaults: UserDefaults) -> BrowserUserAgent {
        if let stored = defaults.string(forKey: storageKey) {
            switch stored {
            case "iphone": return .iPhone
            case "ipad": return .iPad
            case "safari": return .safari
            case "chrome": return .chrome
            default:
                if stored.hasPrefix("custom:"), let agent = validatedCustom(String(stored.dropFirst(7))) { return agent }
                return .default
            }
        }
        // Earlier builds stored a mobile/desktop switch.
        if let mobile = defaults.object(forKey: legacyMobileKey) as? Bool { return mobile ? .iPhone : .safari }
        return .default
    }

    func save(to defaults: UserDefaults) {
        let value: String
        switch self {
        case .iPhone: value = "iphone"
        case .iPad: value = "ipad"
        case .safari: value = "safari"
        case .chrome: value = "chrome"
        case .custom(let text): value = "custom:" + text
        }
        defaults.set(value, forKey: Self.storageKey)
    }
}

struct BrowserBookmark: Codable, Equatable, Identifiable {
    var title: String
    var url: URL
    var id: String { url.absoluteString }

    static let suggestions: [BrowserBookmark] = [
        ("必应", "https://www.bing.com"), ("百度", "https://www.baidu.com"),
        ("GitHub", "https://github.com"), ("维基百科", "https://zh.wikipedia.org"),
    ].compactMap { title, address in URL(string: address).map { BrowserBookmark(title: title, url: $0) } }
}

@MainActor
final class BrowserBookmarks {
    static let shared = BrowserBookmarks()
    static let limit = 30
    private let defaults: UserDefaults
    private let key = "browser.bookmarks"
    private(set) var items: [BrowserBookmark]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([BrowserBookmark].self, from: $0) } ?? []
    }

    func contains(_ url: URL?) -> Bool { url.map { url in items.contains { $0.url == url } } ?? false }

    /// Adds a web page, newest first. Returns false for non-web addresses or when the list is full.
    @discardableResult
    func add(title: String, url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()), !contains(url) else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard items.count < Self.limit else { return false }
        items.insert(BrowserBookmark(title: name.isEmpty ? (url.host ?? url.absoluteString) : name, url: url), at: 0)
        save()
        return true
    }

    func remove(_ url: URL) {
        guard contains(url) else { return }
        items.removeAll { $0.url == url }
        save()
    }

    private func save() {
        // Never overwrite the stored list with nothing if encoding fails.
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Self-contained pages the browser shows itself.
enum BrowserPages {
    static let startTitle = "新页签"

    static func start(_ bookmarks: [BrowserBookmark]) -> String {
        let list = bookmarks.isEmpty ? BrowserBookmark.suggestions : bookmarks
        let rows = list.map { item in
            "<a href=\"\(escape(item.url.absoluteString))\"><b>\(escape(String(item.title.prefix(1))))</b><span>\(escape(item.title))</span></a>"
        }.joined()
        let heading = bookmarks.isEmpty ? "常用网站" : "收藏夹"
        return page(title: startTitle, body: "<h1>\(heading)</h1>\(rows)")
    }

    static func failure(url: URL?, message: String) -> String {
        let retry = url.map { "<a class=\"retry\" href=\"\(escape($0.absoluteString))\"><span>重试</span></a>" } ?? ""
        return page(title: "无法打开网页", body: "<h1>无法打开网页</h1><p>\(escape(message))</p>\(retry)")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light; }
        body { margin: 0; padding: 12px; font: 13px -apple-system, "PingFang SC", sans-serif; color: #363636; background: #fff; }
        h1 { margin: 4px 0 10px; font-size: 14px; font-weight: 600; }
        p { margin: 0 0 12px; color: #9a9a9a; word-break: break-word; }
        a { display: flex; align-items: center; gap: 8px; padding: 7px 8px; margin-bottom: 4px;
            border-radius: 6px; color: inherit; text-decoration: none; background: #f4f4f4; }
        a b { flex: none; width: 22px; height: 22px; border-radius: 5px; background: #e4e4e4;
              text-align: center; line-height: 22px; font-size: 12px; }
        a span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        a.retry { justify-content: center; }
        </style></head><body>\(body)</body></html>
        """
    }
}
