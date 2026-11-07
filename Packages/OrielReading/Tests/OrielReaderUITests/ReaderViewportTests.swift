import AppKit
import SwiftUI
import XCTest
import OrielReading
import OrielReaderUI

@MainActor
final class ReaderViewportTests: XCTestCase {
    private func page(_ chapter: NovelChapter, offset: Int = 0, simplified: Bool = false, font: CGFloat = 16) -> NovelPageView {
        NovelPageView(bookID: "fixture", chapter: chapter, index: 0, offset: offset, highlight: nil,
                      simplified: simplified, fontSize: font, onPosition: { _ in }, onTurn: { _ in })
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testFirstLineIsVisibleAndReflowRetainsTheReadingPassage() async throws {
        _ = NSApplication.shared
        let paragraphs = (0..<100).map { "段落\($0)。風穿過岸邊的柳樹，水面起了一層細紋。" }
        let source = Data(("第一章 河岸\n" + paragraphs.joined(separator: "\n\n")).utf8)
        let chapter = try XCTUnwrap(NovelText.chapters(data: source).first)
        let host = NSHostingView(rootView: page(chapter))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 272, height: 274),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = host
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1)
        XCTAssertTrue(text.string.hasPrefix("第一章 河岸"))

        // Locate a known paragraph through TextKit's rendered layout, then perform
        // the same clip-view scrolling as a trackpad. Verify the visible passage.
        let manager = try XCTUnwrap(text.layoutManager)
        let needle = (text.string as NSString).range(of: "段落48。").location
        let glyph = manager.glyphIndexForCharacter(at: needle)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + text.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        func topCharacter() -> Int {
            let y = max(0, scroll.documentVisibleRect.minY - text.textContainerOrigin.y)
            let index = manager.glyphIndex(for: NSPoint(x: 1, y: y + 0.5), in: text.textContainer!)
            return manager.characterIndexForGlyph(at: index)
        }
        XCTAssertEqual(topCharacter(), needle, accuracy: 2)
        panel.setContentSize(CGSize(width: 174, height: 160))
        host.rootView = page(chapter, simplified: true, font: 19)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertTrue(text.string.contains("风穿过岸边"))
        XCTAssertEqual(topCharacter(), needle, accuracy: 15)
    }
}

extension ReaderViewportTests {
    func testSpaceContinuesToNextChapterWhenThePageAlreadyFits() throws {
        _ = NSApplication.shared
        let chapter = try XCTUnwrap(NovelText.chapters(data: Data("第一回\n天晴了。".utf8)).first)
        var direction = 0
        let page = NovelPageView(bookID: "short", chapter: chapter, index: 0, offset: 0,
                                 highlight: nil, simplified: false, fontSize: 16,
                                 onPosition: { _ in }, onTurn: { direction = $0 })
        let host = NSHostingView(rootView: page)
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 272, height: 274),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        text.keyDown(with: event)
        XCTAssertEqual(direction, 1)
    }
}
