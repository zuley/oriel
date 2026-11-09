import AppKit
import WebKit

/// A small browser for one window tab: address bar, navigation, mobile/desktop sites, zoom,
/// favorites and downloads. Website data (logins, cookies) is shared by every browser tab.
@MainActor
final class BrowserView: NSView, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSTextFieldDelegate {
    private static let toolbarHeight: CGFloat = 30
    private static let ink = ChromePalette.ink
    private static let quiet = OrielPalette.secondary

    /// Called when the text shown for this page's tab changes.
    var onTitleChange: (() -> Void)?

    private let webView: WKWebView
    private let bookmarks: BrowserBookmarks
    private let defaults: UserDefaults
    private let backButton: ToolbarButton
    private let forwardButton: ToolbarButton
    private let reloadButton: ToolbarButton
    private let menuButton: ToolbarButton
    private let addressPill = AddressPill()
    private let addressField = AddressField()
    private let secureIcon = NSImageView()
    private let divider = NSView()
    private let progressBar = NSView()
    private var addressEditing = false
    private var typedAddress = ""
    private var pageEditing = false
    private var crashReloads = 0
    private let scriptHandler = EditingScriptHandler()
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: (download: WKDownload, destination: URL)] = [:]
    private var errorURL: URL?
    private var reportedTitle = ""
    private var isDisposed = false
    private var userAgent: BrowserUserAgent

    override var isFlipped: Bool { true }

    var pageTitle: String {
        if let title = webView.title, !title.isEmpty { return title }
        return webView.url?.host ?? BrowserPages.startTitle
    }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var isEditingAddress: Bool { (window?.firstResponder as? NSTextView)?.delegate === addressField }
    /// True while text is being typed in the address bar or in a field inside the page.
    var hasEditingFocus: Bool { isEditingAddress || pageEditing }

    init(frame: NSRect, bookmarks: BrowserBookmarks = .shared, defaults: UserDefaults = .standard) {
        self.bookmarks = bookmarks
        self.defaults = defaults
        userAgent = BrowserUserAgent.load(from: defaults)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WKUserScript(
            source: EditingScriptHandler.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(scriptHandler, name: EditingScriptHandler.name)
        webView = WKWebView(frame: .zero, configuration: configuration)
        func button(_ symbol: String, _ label: String) -> ToolbarButton {
            let button = ToolbarButton()
            button.image = Self.symbol(symbol, label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = Self.ink
            button.toolTip = label
            button.setAccessibilityLabel(label)
            return button
        }
        backButton = button("chevron.left", "后退")
        forwardButton = button("chevron.right", "前进")
        reloadButton = button("arrow.clockwise", "刷新")
        menuButton = button("ellipsis", "更多")
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = OrielPalette.surface.cgColor
        appearance = NSAppearance(named: .aqua)
        for (control, action) in [(backButton, #selector(goBackPressed)), (forwardButton, #selector(goForwardPressed)),
                                  (reloadButton, #selector(reloadPressed)), (menuButton, #selector(showMenu))] {
            control.target = self
            control.action = action
            addSubview(control)
        }
        addSubview(addressPill)
        addressPill.onFocusRequest = { [weak self] in self?.focusAddress() }
        addressField.placeholderString = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 12)
        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.cell?.isScrollable = true
        addressField.drawsBackground = false
        addressField.textColor = Self.ink
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.alignment = .center
        addressField.setAccessibilityLabel("地址栏")
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(submitAddress)
        addressField.onWillFocus = { [weak self] in self?.beginAddressEditing() }
        addressPill.addSubview(addressField)
        secureIcon.image = Self.symbol("lock.fill", "安全连接", size: 9)
        secureIcon.contentTintColor = Self.quiet
        secureIcon.imageScaling = .scaleNone
        secureIcon.isHidden = true
        addressPill.addSubview(secureIcon)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ChromePalette.divider.cgColor
        addSubview(divider)
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = OrielPalette.accent.cgColor
        progressBar.isHidden = true
        addSubview(progressBar)

        scriptHandler.onChange = { [weak self] editing in self?.pageEditing = editing }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = userAgent.string
        addSubview(webView)
        observe()
        refreshState()
    }

    required init?(coder: NSCoder) { nil }

    private func observe() {
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
            webView.observe(keyPath, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshState() }
            }
        }
        observations = [watch(\.title), watch(\.url), watch(\.canGoBack), watch(\.canGoForward),
                        watch(\.isLoading), watch(\.estimatedProgress)]
    }

    // MARK: Layout and state

    override func layout() {
        super.layout()
        let height = Self.toolbarHeight
        let width = bounds.width
        let showNavigation = width >= 200
        let showReload = width >= 150
        var x: CGFloat = 3
        for (control, visible) in [(backButton, showNavigation), (forwardButton, showNavigation), (reloadButton, showReload)] {
            control.isHidden = !visible
            if visible {
                control.frame = NSRect(x: x, y: 3, width: 24, height: 24)
                x += 24
            }
        }
        let menuX = max(x, width - 27)
        menuButton.frame = NSRect(x: menuX, y: 3, width: 24, height: 24)
        addressPill.frame = NSRect(x: x + 2, y: 4, width: max(0, menuX - x - 4), height: 22)
        layoutAddress()
        divider.frame = NSRect(x: 0, y: height - 1, width: width, height: 1)
        webView.frame = NSRect(x: 0, y: height, width: width, height: max(0, bounds.height - height))
        layoutProgress()
    }

    private static func symbol(_ name: String, _ label: String, size: CGFloat = 12) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    /// The site is centered beside a lock while idle; editing uses the full width.
    private func layoutAddress() {
        let width = addressPill.bounds.width
        let showIcon = !addressEditing && width >= 120 && BrowserAddress.isSecure(webView.url)
        secureIcon.isHidden = !showIcon
        secureIcon.frame = NSRect(x: 8, y: (addressPill.bounds.height - 12) / 2, width: 12, height: 12)
        let leading: CGFloat = addressEditing ? 6 : (width >= 120 ? 22 : 6)
        // Give the native text field its natural line height, centered in the pill.
        // Drawing and the shared field editor then use the same control bounds.
        let pillHeight = addressPill.bounds.height
        let textHeight = min(pillHeight, ceil(addressField.cell?.cellSize.height ?? pillHeight))
        addressField.frame = NSRect(x: leading, y: (pillHeight - textHeight) / 2,
                                   width: max(0, width - leading - 6), height: textHeight)
    }

    private func beginAddressEditing() {
        addressEditing = true
        typedAddress = BrowserAddress.display(webView.url)
        addressField.stringValue = typedAddress
        addressField.alignment = .left
        addressField.textColor = Self.ink
        addressPill.isFocused = true
        layoutAddress()
    }

    private func endAddressEditing() {
        guard addressEditing else { return }
        addressEditing = false
        updateAddress()
    }

    private func updateAddress() {
        guard !addressEditing else { return }
        addressField.stringValue = BrowserAddress.compact(webView.url)
        addressField.alignment = .center
        addressField.textColor = Self.quiet
        addressPill.isFocused = false
        layoutAddress()
    }

    func controlTextDidChange(_ notification: Notification) {
        typedAddress = (notification.userInfo?["NSFieldEditor"] as? NSText)?.string ?? addressField.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) { endAddressEditing() }

    private func layoutProgress() {
        let fraction = webView.isLoading ? max(0.08, webView.estimatedProgress) : 0
        progressBar.frame = NSRect(x: 0, y: Self.toolbarHeight - 2, width: bounds.width * fraction, height: 2)
        progressBar.isHidden = !webView.isLoading
    }

    private func refreshState() {
        guard !isDisposed else { return }
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        let loading = webView.isLoading
        reloadButton.image = Self.symbol(loading ? "xmark" : "arrow.clockwise", loading ? "停止" : "刷新")
        reloadButton.toolTip = loading ? "停止" : "刷新"
        reloadButton.setAccessibilityLabel(loading ? "停止" : "刷新")
        updateAddress()
        layoutProgress()
        if reportedTitle != pageTitle {
            reportedTitle = pageTitle
            onTitleChange?()
        }
    }

    // MARK: Commands

    func load(_ url: URL) {
        errorURL = nil
        webView.load(URLRequest(url: url))
    }

    func showStartPage() {
        errorURL = nil
        webView.loadHTMLString(BrowserPages.start(bookmarks.items), baseURL: nil)
    }

    func focusAddress() {
        // Finish the first layout before AppKit creates the shared text editor.
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(addressField)
    }

    /// Keyboard focus goes to the page, so arrow keys and space scroll it right after switching in.
    func focusContent() { window?.makeFirstResponder(webView) }

    /// Called when the page is no longer on screen so it stops playing in the background.
    func pauseMedia() { webView.pauseAllMediaPlayback {} }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if let errorURL {
            load(errorURL)
        } else if webView.url == nil || webView.url?.scheme == "about" {
            showStartPage()
        } else {
            webView.reload()
        }
    }

    func zoomIn() { webView.pageZoom = BrowserZoom.zoomedIn(webView.pageZoom) }
    func zoomOut() { webView.pageZoom = BrowserZoom.zoomedOut(webView.pageZoom) }
    func resetZoom() { webView.pageZoom = BrowserZoom.default }

    func toggleBookmark() {
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased()) else {
            NSSound.beep()
            return
        }
        if bookmarks.contains(url) {
            bookmarks.remove(url)
        } else if !bookmarks.add(title: pageTitle, url: url) {
            inform("无法收藏", "收藏夹最多 \(BrowserBookmarks.limit) 项，请先取消一些收藏。")
        }
    }

    private func inform(_ title: String, _ detail: String) {
        guard let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        observations.removeAll()
        onTitleChange = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: EditingScriptHandler.name)
        scriptHandler.onChange = nil
        addressField.delegate = nil
        for entry in downloads.values { entry.download.cancel { _ in } }
        downloads.removeAll()
        webView.removeFromSuperview()
        removeFromSuperview()
    }

    @objc private func goBackPressed() { goBack() }
    @objc private func goForwardPressed() { goForward() }
    @objc private func reloadPressed() {
        if webView.isLoading { webView.stopLoading() } else { reload() }
    }

    @objc private func submitAddress() {
        guard let url = BrowserAddress.resolve(typedAddress) else {
            NSSound.beep()
            return
        }
        load(url)
        window?.makeFirstResponder(webView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(webView)
        return true
    }

    // MARK: Menu

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let url = webView.url
        let isWebPage = ["http", "https"].contains(url?.scheme?.lowercased())

        let bookmarked = bookmarks.contains(url)
        add(to: menu, bookmarked ? "取消收藏此页" : "收藏此页", #selector(bookmarkAction), enabled: isWebPage || bookmarked, key: "d")
        let favorites = NSMenuItem(title: "收藏夹", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for item in bookmarks.items {
            let entry = NSMenuItem(title: item.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.url
            entry.toolTip = item.url.absoluteString
            submenu.addItem(entry)
        }
        if bookmarks.items.isEmpty { submenu.addItem(NSMenuItem(title: "暂无收藏", action: nil, keyEquivalent: "")) }
        favorites.submenu = submenu
        menu.addItem(favorites)
        menu.addItem(.separator())

        let agentItem = NSMenuItem(title: "User Agent（\(userAgent.title)）", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu()
        agentMenu.autoenablesItems = false
        for preset in BrowserUserAgent.presets {
            let entry = NSMenuItem(title: preset.title, action: #selector(selectUserAgent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = UserAgentChoice(preset)
            entry.state = preset == userAgent ? .on : .off
            entry.toolTip = preset.string ?? "WebKit 默认"
            agentMenu.addItem(entry)
        }
        agentMenu.addItem(.separator())
        let custom = NSMenuItem(title: "自定义…", action: #selector(editCustomUserAgent), keyEquivalent: "")
        custom.target = self
        if case .custom(let value) = userAgent {
            custom.state = .on
            custom.toolTip = value
        }
        agentMenu.addItem(custom)
        agentItem.submenu = agentMenu
        menu.addItem(agentItem)
        menu.addItem(.separator())
        add(to: menu, "放大", #selector(zoomInAction), enabled: true, key: "=")
        add(to: menu, "缩小", #selector(zoomOutAction), enabled: true, key: "-")
        add(to: menu, "实际大小（\(Int((webView.pageZoom * 100).rounded()))%）", #selector(resetZoomAction), enabled: true, key: "0")
        menu.addItem(.separator())
        add(to: menu, "在默认浏览器中打开", #selector(openExternally), enabled: isWebPage)
        add(to: menu, "拷贝链接", #selector(copyLink), enabled: isWebPage)
        menu.addItem(.separator())
        add(to: menu, "清除浏览数据…", #selector(clearBrowsingData), enabled: true)
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 2), in: self)
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if !key.isEmpty { item.keyEquivalentModifierMask = .command }
        menu.addItem(item)
        return item
    }

    @objc private func bookmarkAction() { toggleBookmark() }
    @objc private func openBookmark(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { load(url) }
    }
    @objc private func zoomInAction() { zoomIn() }
    @objc private func zoomOutAction() { zoomOut() }
    @objc private func resetZoomAction() { resetZoom() }

    private final class UserAgentChoice: NSObject {
        let agent: BrowserUserAgent
        init(_ agent: BrowserUserAgent) { self.agent = agent }
    }

    @objc private func selectUserAgent(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? UserAgentChoice else { return }
        apply(choice.agent)
    }

    private func apply(_ agent: BrowserUserAgent) {
        guard agent != userAgent else { return }
        userAgent = agent
        agent.save(to: defaults)
        webView.customUserAgent = agent.string
        if webView.url != nil { reload() }
    }

    @objc private func editCustomUserAgent() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "自定义 User Agent"
        alert.informativeText = "单行文本，最多 \(BrowserUserAgent.customLimit) 个字符。保存后当前页面会重新加载。"
        let save = alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let field = UserAgentField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = BrowserUserAgent.iPhone.string
        if case .custom(let value) = userAgent { field.stringValue = value }
        field.setAccessibilityLabel("User Agent")
        field.saveButton = save
        field.delegate = field
        save.isEnabled = BrowserUserAgent.validatedCustom(field.stringValue) != nil
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, field] response in
            guard response == .alertFirstButtonReturn,
                  let agent = BrowserUserAgent.validatedCustom(field.stringValue) else { return }
            self?.apply(agent)
        }
    }

    @objc private func openExternally() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    @objc private func copyLink() {
        guard let url = webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func clearBrowsingData() {
        let alert = NSAlert()
        alert.messageText = "清除浏览数据？"
        alert.informativeText = "将清除所有小窗中浏览器的登录状态、Cookie 和缓存，收藏夹不受影响。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let clear = {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                    modifiedSince: .distantPast) {}
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { clear() }
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = userAgent.usesMobileContent ? .mobile : .desktop
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        if navigationAction.navigationType != .other { errorURL = nil }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob":
            return (.allow, preferences)
        case "data":
            // A page may embed data: resources, but cannot send the whole tab to one.
            return (navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel, preferences)
        default:
            // Apps such as mail or maps are launched only by an explicit click.
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageEditing = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { crashReloads = 0 }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageEditing = false
        // A page that keeps crashing must not reload forever.
        guard crashReloads < 2 else {
            let failing = webView.url
            errorURL = failing
            webView.loadHTMLString(BrowserPages.failure(url: failing, message: "网页反复崩溃，已停止自动重新加载。"), baseURL: failing)
            return
        }
        crashReloads += 1
        webView.reload()
    }

    private func showFailure(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads (a new navigation, or the download handoff) are not failures.
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let handedOff = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        guard !cancelled, !handedOff else { return }
        let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        errorURL = failing
        webView.loadHTMLString(BrowserPages.failure(url: failing, message: nsError.localizedDescription), baseURL: failing)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The small window has no room for pop-ups; open them in place.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await present(message, host: frame.request.url?.host, confirming: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(message, host: frame.request.url?.host, confirming: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "网页"
        alert.informativeText = prompt
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func present(_ message: String, host: String?, confirming: Bool) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = host ?? "网页"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if confirming { alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}" }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        let proposed = (suggestedFilename as NSString).lastPathComponent
        let name = ["", ".", ".."].contains(proposed) ? "download" : proposed
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = folder.appending(path: name)
        var index = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        downloads[ObjectIdentifier(download)] = (download, destination)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.destination])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        try? FileManager.default.removeItem(at: entry.destination)
        inform("下载失败", "\(entry.destination.lastPathComponent)：\(error.localizedDescription)")
    }
}

@MainActor
private final class UserAgentField: NSTextField, NSTextFieldDelegate {
    weak var saveButton: NSButton?
    func controlTextDidChange(_ notification: Notification) {
        saveButton?.isEnabled = BrowserUserAgent.validatedCustom(stringValue) != nil
    }
}

/// The rounded surface behind the address; turns white with an outline while editing.
@MainActor
private final class AddressPill: NSView {
    var isFocused = false { didSet { refresh() } }
    var onFocusRequest: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
    }

    private func refresh() {
        layer?.backgroundColor = isFocused
            ? OrielPalette.surface.cgColor
            : OrielPalette.field.cgColor
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = OrielPalette.accent.cgColor
    }
}

@MainActor
private final class AddressField: NSTextField {
    var onWillFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // The first click opens the full address with everything selected, as in Safari.
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }

    override func becomeFirstResponder() -> Bool {
        onWillFocus?()
        let accepted = super.becomeFirstResponder()
        if accepted { currentEditor()?.selectAll(nil) }
        return accepted
    }
}

/// A flat toolbar button with a soft hover highlight and a dimmed disabled state.
@MainActor
private final class ToolbarButton: NSButton {
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.3
            if !isEnabled { setHover(false) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { setHover(true) } }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ hovered: Bool) {
        layer?.backgroundColor = hovered ? ChromePalette.hover.cgColor : nil
    }
}

/// Reports whether a text field inside the page has keyboard focus, so edge-hide never
/// takes the window away while the user is typing (for example in a login form).
@MainActor
private final class EditingScriptHandler: NSObject, WKScriptMessageHandler {
    static let name = "orielEditing"
    static let script = """
    (function () {
      function editable(t) {
        if (!t) return false;
        if (t.isContentEditable) return true;
        if (t.tagName === 'TEXTAREA' || t.tagName === 'SELECT') return true;
        if (t.tagName !== 'INPUT') return false;
        return !['button', 'checkbox', 'radio', 'submit', 'reset', 'image', 'file', 'range', 'color'].includes((t.type || '').toLowerCase());
      }
      function report(value) { window.webkit.messageHandlers.orielEditing.postMessage(value); }
      document.addEventListener('focusin', function (e) { report(editable(e.target)); }, true);
      document.addEventListener('focusout', function () { report(false); }, true);
    })();
    """

    var onChange: ((Bool) -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let editing = (message.body as? Bool) ?? false
        MainActor.assumeIsolated { onChange?(editing) }
    }
}
