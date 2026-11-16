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
        case .custom: return L("自定义")
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

    /// Computed (not a `static let`) so quick-link names follow a language switch.
    static var suggestions: [BrowserBookmark] {
        [(L("必应"), "https://www.bing.com"), (L("百度"), "https://www.baidu.com"),
         ("GitHub", "https://github.com"), (L("维基百科"), "https://www.wikipedia.org")]
            .compactMap { title, address in URL(string: address).map { BrowserBookmark(title: title, url: $0) } }
    }
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
    static var startTitle: String { L("新页签") }

    /// The start page is an icon desktop: one rounded monogram tile above each
    /// name, so a dozen bookmarks stay scannable in a mini window.
    static func start(_ bookmarks: [BrowserBookmark]) -> String {
        let list = bookmarks.isEmpty ? BrowserBookmark.suggestions : bookmarks
        let tiles = list.map { item -> String in
            let initial = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .first.map { String($0).uppercased() } ?? "·"
            return "<a href=\"\(escape(item.url.absoluteString))\">"
                + "<i style=\"background:\(tint(for: item.url.host ?? item.url.absoluteString))\">\(escape(initial))</i>"
                + "<span>\(escape(item.title))</span></a>"
        }.joined()
        let heading = bookmarks.isEmpty ? L("常用网站") : L("收藏夹")
        return page(title: startTitle,
                    body: "<h1 class=\"label\">\(heading)</h1><div class=\"desktop\">\(tiles)</div>")
    }

    /// A stable tile colour per site, so a bookmark keeps the same icon between launches.
    /// Swift's own hashing is seeded per process, hence the explicit FNV-1a.
    private static func tint(for host: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let pair = iconTints[Int(hash % UInt64(iconTints.count))]
        return "linear-gradient(160deg, \(pair.0), \(pair.1))"
    }

    /// Muted, close to the accent red of the rest of the app.
    private static let iconTints: [(String, String)] = [
        ("#C2624E", "#A63C2C"), ("#7089A6", "#4E6A87"), ("#6E9284", "#4D7466"),
        ("#A98363", "#86634A"), ("#8B7E9F", "#6C5F85"), ("#5F8C8F", "#447073"),
    ]

    static func failure(url: URL?, message: String) -> String {
        let retry = url.map {
            L(#"<a class="retry" href="%@"><span>重试</span></a>"#, escape($0.absoluteString))
        } ?? ""
        return page(title: L("无法打开网页"),
                    body: L(#"<h1>无法打开网页</h1><p>%@</p>%@"#, escape(message), retry))
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
        \(OrielPalette.browserCSS)
        body { margin: 0; padding: 12px; font: 13px -apple-system, "PingFang SC", sans-serif; color: var(--oriel-ink); background: var(--oriel-canvas); }
        h1 { margin: 4px 0 10px; font-size: 14px; font-weight: 600; }
        h1.label { margin: 4px 0 14px; font-size: 11px; font-weight: 600; letter-spacing: .08em;
                   text-align: center; color: var(--oriel-muted); }
        p { margin: 0 0 12px; color: var(--oriel-muted); word-break: break-word; }
        a { color: inherit; text-decoration: none; }
        a:focus-visible { outline: 2px solid var(--oriel-accent); outline-offset: 2px; }
        ::selection { background: var(--oriel-highlight); color: var(--oriel-ink); }
        .desktop { display: grid; grid-template-columns: repeat(auto-fill, minmax(62px, 1fr));
                   gap: 14px 4px; align-content: start; }
        .desktop a { display: flex; flex-direction: column; align-items: center; gap: 6px;
                     padding: 2px; border-radius: 9px; }
        .desktop a i { display: flex; align-items: center; justify-content: center; width: 46px; height: 46px;
                       border-radius: 12px; font-style: normal; font-size: 19px; font-weight: 600;
                       color: rgba(255,255,255,.95);
                       box-shadow: 0 1px 2px rgba(54,54,54,.16), inset 0 1px 0 rgba(255,255,255,.18);
                       transition: transform .15s ease, box-shadow .15s ease; }
        .desktop a:hover i, .desktop a:active i { transform: translateY(-1px);
                       box-shadow: 0 3px 7px rgba(54,54,54,.22), inset 0 1px 0 rgba(255,255,255,.22); }
        .desktop a:focus-visible { outline: none; }
        .desktop a:focus-visible i { outline: 2px solid var(--oriel-accent); outline-offset: 2px; }
        .desktop a span { max-width: 100%; font-size: 10.5px; line-height: 1.3; text-align: center;
                          color: var(--oriel-ink); display: -webkit-box; -webkit-box-orient: vertical;
                          -webkit-line-clamp: 2; overflow: hidden; word-break: break-word; }
        a.retry { display: flex; align-items: center; justify-content: center; padding: 7px 8px;
                  border-radius: 6px; background: var(--oriel-field); }
        a.retry:hover, a.retry:active { background: var(--oriel-selection); }
        </style></head><body>\(body)</body></html>
        """
    }
}
