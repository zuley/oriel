import AppKit
import SwiftUI
import XCTest
import OrielReading
import OrielReaderUI

/// R00 baselines (docs/plans/017-refactor-tasks.md): resizing a reader that shows
/// one chapter of about 1 MiB. They report timings and assert no speed threshold.
@MainActor
final class ReaderPerformanceTests: XCTestCase {
    private func makeReader() throws -> (NSPanel, NSHostingView<NovelPageView>) {
        _ = NSApplication.shared
        let paragraph = "風穿過岸邊的柳樹，水面起了一層細紋，遠處有人在唱歌。"
        var body = ""
        while body.utf8.count < 1_000_000 { body += paragraph + "\n\n" }
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

    /// P5: 30 width resizes, as when dragging a side edge; every step reflows the chapter.
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
    }
}
