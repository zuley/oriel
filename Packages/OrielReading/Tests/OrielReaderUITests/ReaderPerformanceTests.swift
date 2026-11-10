import AppKit
import SwiftUI
import XCTest
import OrielReading
import OrielReaderUI

/// R00/R20 baselines (docs/plans/017-refactor-tasks.md): resizing a reader that shows
/// one chapter of about 1 MiB. Timings are reported; behavior is asserted.
@MainActor
final class ReaderPerformanceTests: XCTestCase {
    private func makeReader() throws -> (NSPanel, NSHostingView<NovelPageView>) {
        _ = NSApplication.shared
        let paragraph = "風穿過岸邊的柳樹，水面起了一層細紋，遠處有人在唱歌。"
        var body = ""
        var index = 0
        while body.utf8.count < 1_000_000 { body += "段落\(index)。" + paragraph + "\n\n"; index += 1 }
        // The memberwise initializer is internal; build the chapter as the shelf stores it.
        let json = try JSONEncoder().encode(["title": "第一章 河岸", "text": body])
        let chapter = try JSONDecoder().decode(NovelChapter.self, from: json)
        let page = NovelPageView(bookID: "perf", chapter: chapter, index: 0, offset: 0, highlight: nil,
                                 simplified: false, fontSize: 13, onPosition: { _ in }, onTurn: { _ in })
        let host = NSHostingView(rootView: page)
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 272, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (panel, host)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// P4: 30 height-only resizes, as when dragging the bottom edge.
    func testP4HeightOnlyResize() throws {
        let (panel, host) = try makeReader()
        defer { panel.close() }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            for step in 0..<30 {
                panel.setContentSize(CGSize(width: 272, height: 300 + CGFloat(step % 15) * 8))
                host.layoutSubtreeIfNeeded()
            }
        }
    }

    /// P5: 30 width resizes in quick succession, as when dragging a side edge.
    func testP5WidthResize() throws {
        let (panel, host) = try makeReader()
        defer { panel.close() }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            for step in 0..<30 {
                panel.setContentSize(CGSize(width: 272 + CGFloat(step % 15) * 8, height: 300))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle()
    }

    /// P5b: from the last drag step until the text wraps at the new width. Includes the
    /// 150 ms settle delay; subtract it for the reflow itself.
    func testP5bReflowAfterResizeSettles() throws {
        let (panel, host) = try makeReader()
        defer { panel.close() }
        let text = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var width: CGFloat = 272
        measure(metrics: [XCTClockMetric()], options: options) {
            width = width == 272 ? 330 : 272
            panel.setContentSize(CGSize(width: width, height: 300))
            host.layoutSubtreeIfNeeded()
            let usable = { scroll.contentSize.width - 2 * text.textContainerInset.width }
            startMeasuring()
            let deadline = Date().addingTimeInterval(3)
            while abs((text.textContainer?.size.width ?? 0) - usable()) > 1, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            stopMeasuring()
        }
    }

    /// R20: a drag keeps the passage on screen; text reflows to the final width once settled.
    func testWidthDragKeepsPassageAndReflowsOnceSettled() throws {
        let (panel, host) = try makeReader()
        defer { panel.close() }
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        func topCharacter() -> Int {
            let y = max(0, scroll.documentVisibleRect.minY - text.textContainerOrigin.y)
            return manager.characterIndexForGlyph(at: manager.glyphIndex(for: NSPoint(x: 1, y: y + 0.5), in: container))
        }
        // Scroll to a passage in the middle of the chapter.
        let needle = (text.string as NSString).range(of: "段落9000。").location
        XCTAssertNotEqual(needle, NSNotFound)
        let rect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: needle), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + text.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(topCharacter(), needle, accuracy: 2)

        for step in 1...20 {
            panel.setContentSize(CGSize(width: 272 + CGFloat(step) * 4, height: 300))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(topCharacter(), needle, accuracy: 40, "The passage stays put during the drag.")
        }
        settle()
        let usable = scroll.contentSize.width - 2 * text.textContainerInset.width
        XCTAssertEqual(container.size.width, usable, accuracy: 1, "Text wraps at the final width.")
        XCTAssertEqual(topCharacter(), needle, accuracy: 40, "The passage is restored after the reflow.")
    }
}
