import XCTest

@MainActor
final class BrowserModelTests: XCTestCase {
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
        XCTAssertTrue(start.contains("收藏夹"))
        XCTAssertTrue(BrowserPages.start([]).contains("常用网站"))
        let failure = BrowserPages.failure(url: hostile.url, message: "<b>offline</b>")
        XCTAssertFalse(failure.contains("<b>offline"))
        XCTAssertTrue(failure.contains("重试"))
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
