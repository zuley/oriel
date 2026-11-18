import XCTest
import WebKit

@MainActor
final class BrowserModelTests: XCTestCase {
    func testWebKitPublishesBothDownloadsWithTheSameSuggestedName() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = expectation(description: "WebKit finished both downloads")
        finished.expectedFulfillmentCount = 2
        var published: [URL] = []
        let browsers = (0..<2).map { _ in
            BrowserView(frame: .zero, downloadFolder: folder) { url in
                published.append(url)
                finished.fulfill()
            }
        }
        defer { browsers.forEach { $0.dispose() } }
        for (index, browser) in browsers.enumerated() {
            let web = try XCTUnwrap(browser.subviews.compactMap { $0 as? WKWebView }.first)
            _ = try await web.callAsyncJavaScript("""
                const link = document.createElement('a');
                link.href = URL.createObjectURL(new Blob([text], {type: 'text/plain'}));
                link.download = 'report.txt';
                document.body.append(link);
                link.click();
                """, arguments: ["text": "report \(index)"], in: nil, contentWorld: .page)
        }
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertEqual(Set(published.map(\.lastPathComponent)), ["report.txt", "report 1.txt"])
        XCTAssertEqual(Set(try published.map { try String(contentsOf: $0, encoding: .utf8) }), ["report 0", "report 1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testConcurrentDownloadsPublishDistinctFilesAndCleanOnlyTheirOwnStaging() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "日报.txt"
        let files = try (0..<3).map { _ in try BrowserDownloadFile(in: folder, suggestedFilename: name) }
        for (index, file) in files.enumerated() { try Data([UInt8(index)]).write(to: file.temporaryURL) }
        let existing = folder.appending(path: name)
        try Data([42]).write(to: existing)

        let results = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for file in files.prefix(2) {
                group.addTask {
                    defer { file.discardStaging() }
                    return try file.publish()
                }
            }
            var published: [URL] = []
            for try await result in group { published.append(result) }
            return published
        }
        files[2].discardStaging() // The failed or cancelled download.
        XCTAssertEqual(Set(results.map(\.lastPathComponent)), ["日报 1.txt", "日报 2.txt"])
        XCTAssertEqual(Set(try results.map { try Data(contentsOf: $0) }), [Data([0]), Data([1])])
        XCTAssertEqual(try Data(contentsOf: existing), Data([42]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testFinishedNavigationsDoNotRearmAutomaticCrashReloads() {
        let browser = BrowserView(frame: .zero)
        defer { browser.dispose() }
        let web = RecordingWebView()
        let delegate: WKNavigationDelegate = browser
        let termination = NSError(domain: WKError.errorDomain, code: WKError.webContentProcessTerminated.rawValue)
        for _ in 0..<4 {
            delegate.webView?(web, didFinish: nil)
            browser.webView(web, didFailProvisionalNavigation: nil, withError: termination)
            browser.webViewWebContentProcessDidTerminate(web)
        }
        browser.webView(web, didFail: nil, withError: URLError(.networkConnectionLost))
        XCTAssertEqual(web.reloadCount, 2)
        XCTAssertEqual(web.errorPages, 1)
        browser.load(URL(string: "about:blank")!)
        browser.webViewWebContentProcessDidTerminate(web)
        XCTAssertEqual(web.reloadCount, 3)
    }

    private final class RecordingWebView: WKWebView {
        var reloadCount = 0
        var errorPages = 0
        override func reload() -> WKNavigation? {
            reloadCount += 1
            return nil
        }
        override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
            errorPages += 1
            return nil
        }
    }

    func testAddressBarLoadsWebAddressesAndSearchesEverythingElse() {
        XCTAssertEqual(BrowserAddress.resolve("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(BrowserAddress.resolve("  example.com  ")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserAddress.resolve("example.com:8080/x")?.absoluteString, "https://example.com:8080/x")
        XCTAssertEqual(BrowserAddress.resolve("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserAddress.resolve("192.168.1.1/admin")?.absoluteString, "http://192.168.1.1/admin")
        XCTAssertEqual(BrowserAddress.resolve("swift concurrency")?.absoluteString, BrowserAddress.searchTemplate + "swift%20concurrency")
        XCTAssertEqual(BrowserAddress.resolve("hello")?.absoluteString, BrowserAddress.searchTemplate + "hello")
        XCTAssertEqual(BrowserAddress.resolve("a&b=c+d")?.absoluteString, BrowserAddress.searchTemplate + "a%26b%3Dc%2Bd")
        XCTAssertEqual(BrowserAddress.resolve("what is example.com")?.absoluteString,
                       BrowserAddress.searchTemplate + "what%20is%20example.com")
    }

    func testAddressBarRejectsEmptyInputAndNonWebSchemes() {
        XCTAssertNil(BrowserAddress.resolve("   "))
        XCTAssertNil(BrowserAddress.resolve("javascript:alert(1)"))
        XCTAssertNil(BrowserAddress.resolve("file:///etc/passwd"))
        XCTAssertNil(BrowserAddress.resolve("http://"))
    }

    func testStartPageAddressIsBlank() {
        XCTAssertEqual(BrowserAddress.display(URL(string: "about:blank")), "")
        XCTAssertEqual(BrowserAddress.display(nil), "")
        XCTAssertEqual(BrowserAddress.display(URL(string: "https://example.com")), "https://example.com")
    }

    func testIdleAddressShowsOnlyTheSite() {
        XCTAssertEqual(BrowserAddress.compact(URL(string: "https://www.bing.com/search?q=swift")), "bing.com")
        XCTAssertEqual(BrowserAddress.compact(URL(string: "http://localhost:3000/a")), "localhost")
        XCTAssertEqual(BrowserAddress.compact(URL(string: "https://zh.wikipedia.org/wiki/A")), "zh.wikipedia.org")
        XCTAssertEqual(BrowserAddress.compact(URL(string: "about:blank")), "")
        XCTAssertEqual(BrowserAddress.compact(nil), "")
        XCTAssertTrue(BrowserAddress.isSecure(URL(string: "https://example.com")))
        XCTAssertFalse(BrowserAddress.isSecure(URL(string: "http://example.com")))
    }

    func testZoomMovesThroughStepsAndStopsAtTheEnds() {
        XCTAssertEqual(BrowserZoom.zoomedIn(1), 1.1)
        XCTAssertEqual(BrowserZoom.zoomedOut(1), 0.9)
        XCTAssertEqual(BrowserZoom.zoomedIn(3), 3)
        XCTAssertEqual(BrowserZoom.zoomedOut(0.5), 0.5)
        XCTAssertEqual(BrowserZoom.zoomedIn(1.05), 1.1)
    }

    func testBookmarksPersistDeduplicateAndOnlyAcceptWebPages() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BrowserBookmarks(defaults: defaults)
        let site = try XCTUnwrap(URL(string: "https://example.com/page"))
        XCTAssertTrue(bookmarks.add(title: " 示例 ", url: site))
        XCTAssertFalse(bookmarks.add(title: "again", url: site))
        XCTAssertFalse(bookmarks.add(title: "local", url: try XCTUnwrap(URL(string: "file:///tmp/a.html"))))
        XCTAssertTrue(bookmarks.add(title: "", url: try XCTUnwrap(URL(string: "https://swift.org"))))
        XCTAssertEqual(bookmarks.items.map(\.title), ["swift.org", "示例"])

        let restored = BrowserBookmarks(defaults: defaults)
        XCTAssertEqual(restored.items, bookmarks.items)
        XCTAssertTrue(restored.contains(site))
        restored.remove(site)
        XCTAssertFalse(BrowserBookmarks(defaults: defaults).contains(site))
    }

    func testBookmarksStopAtTheLimit() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BrowserBookmarks(defaults: defaults)
        for index in 0..<BrowserBookmarks.limit {
            XCTAssertTrue(bookmarks.add(title: "\(index)", url: try XCTUnwrap(URL(string: "https://example.com/\(index)"))))
        }
        XCTAssertFalse(bookmarks.add(title: "extra", url: try XCTUnwrap(URL(string: "https://example.com/extra"))))
        XCTAssertEqual(bookmarks.items.count, BrowserBookmarks.limit)
    }

    func testGeneratedPagesEscapeTitlesAndAddresses() throws {
        let hostile = BrowserBookmark(title: "<script>alert(1)</script>", url: try XCTUnwrap(URL(string: "https://example.com/?a=1&b=\"2\"")))
        let start = BrowserPages.start([hostile])
        XCTAssertFalse(start.contains("<script>"))
        XCTAssertTrue(start.contains("&lt;script&gt;"))
        XCTAssertTrue(start.contains(L("收藏夹")))
        XCTAssertTrue(BrowserPages.start([]).contains(L("常用网站")))
        let failure = BrowserPages.failure(url: hostile.url, message: "<b>offline</b>")
        XCTAssertFalse(failure.contains("<b>offline"))
        XCTAssertTrue(failure.contains(L("重试")))
    }

    func testStartPageDrawsBookmarksAsIconTiles() throws {
        let github = BrowserBookmark(title: "GitHub", url: try XCTUnwrap(URL(string: "https://github.com/")))
        let wiki = BrowserBookmark(title: "维基百科", url: try XCTUnwrap(URL(string: "https://www.wikipedia.org/")))
        let page = BrowserPages.start([github, wiki])
        XCTAssertTrue(page.contains("class=\"desktop\""))
        XCTAssertEqual(page.components(separatedBy: "<a href=").count - 1, 2)
        XCTAssertTrue(page.contains(">G</span>"))
        XCTAssertTrue(page.contains(">维</span>"))
        // The tile loads the site's own icon, then falls back to the drawn letter.
        XCTAssertTrue(page.contains("src=\"https://github.com/apple-touch-icon.png\""))
        XCTAssertTrue(page.contains("this.src='https://github.com/favicon.ico'"))
    }

    func testStartPagePutsLongNamesInATooltip() throws {
        let long = BrowserBookmark(title: "小红书 - 你的生活兴趣社区",
                                   url: try XCTUnwrap(URL(string: "https://www.xiaohongshu.com/")))
        let short = BrowserBookmark(title: "GitHub", url: try XCTUnwrap(URL(string: "https://github.com/")))
        let page = BrowserPages.start([long, short])
        // The visible name is cut to six characters wide; the whole title rides on the tooltip.
        XCTAssertTrue(page.contains("title=\"小红书 - 你的生活兴趣社区\""))
        XCTAssertFalse(page.contains("title=\"GitHub\""))
        XCTAssertTrue(page.contains("max-width: 6em"))
    }

    func testUserAgentChoicePersistsAndMigratesTheOldMobileSwitch() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(BrowserUserAgent.load(from: defaults), .iPhone)

        defaults.set(false, forKey: "browser.mobileSites")
        XCTAssertEqual(BrowserUserAgent.load(from: defaults), .safari)
        defaults.set(true, forKey: "browser.mobileSites")
        XCTAssertEqual(BrowserUserAgent.load(from: defaults), .iPhone)

        for agent in BrowserUserAgent.presets + [.custom("MyAgent/1.0")] {
            agent.save(to: defaults)
            XCTAssertEqual(BrowserUserAgent.load(from: defaults), agent)
        }
        defaults.set("garbage", forKey: "browser.userAgent")
        XCTAssertEqual(BrowserUserAgent.load(from: defaults), .iPhone)
    }

    func testUserAgentPresetsDifferAndOnlyIPhoneUsesMobileContent() {
        XCTAssertNil(BrowserUserAgent.safari.string)
        XCTAssertTrue(BrowserUserAgent.iPhone.string?.contains("iPhone") == true)
        XCTAssertTrue(BrowserUserAgent.iPad.string?.contains("iPad") == true)
        XCTAssertTrue(BrowserUserAgent.chrome.string?.contains("Chrome/") == true)
        XCTAssertEqual(BrowserUserAgent.presets.filter(\.usesMobileContent), [.iPhone])
    }

    func testCustomUserAgentMustBeOneNonEmptyLine() {
        XCTAssertEqual(BrowserUserAgent.validatedCustom("  Foo/1.0 (Bar)  "), .custom("Foo/1.0 (Bar)"))
        XCTAssertNil(BrowserUserAgent.validatedCustom("   "))
        XCTAssertNil(BrowserUserAgent.validatedCustom("Foo\nBar"))
        XCTAssertNil(BrowserUserAgent.validatedCustom("Foo\u{0}Bar"))
        XCTAssertNil(BrowserUserAgent.validatedCustom(String(repeating: "a", count: BrowserUserAgent.customLimit + 1)))
        XCTAssertNotNil(BrowserUserAgent.validatedCustom(String(repeating: "a", count: BrowserUserAgent.customLimit)))
    }
}
