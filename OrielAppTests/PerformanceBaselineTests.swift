import AppKit
import SwiftUI
import XCTest

/// R00 baselines (docs/plans/017-refactor-tasks.md). They assert nothing about speed;
/// compare the reported averages before and after each performance task.
@MainActor
final class PerformanceBaselineTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "oriel-perf-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func options(_ iterations: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    /// About 1,000,000 UTF-8 bytes: CJK lines with blank-line paragraphs.
    private static let largeText: String = {
        let line = "第一章 风穿过岸边的柳树，水面起了一层细纹，远处有人在唱歌。\n"
        var text = "大文件便签\n"
        while text.utf8.count < 1_000_000 { text += line }
        return text
    }()

    /// P1: one save of a 1 MiB note that already exists on disk
    /// (read back, decode, copy to backup, atomic write).
    func testP1SaveLargeNote() throws {
        let store = NotesStore(root: root)
        var record = NoteRecord(id: UUID(), text: Self.largeText, created: Date(), updated: Date())
        try store.save(record)
        var counter = 0
        measure(metrics: [XCTClockMetric()], options: Self.options(10)) {
            counter += 1
            record.text = Self.largeText + String(counter)
            record.updated = Date()
            do { try store.save(record) } catch { XCTFail("save failed: \(error)") }
        }
    }

    /// P2: 200 typed characters into a 1 MiB note through the real editor delegate path
    /// (limit check on a full candidate string, then a model update per keystroke).
    func testP2TypingIntoLargeNote() throws {
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        XCTAssertTrue(document.edit(Self.largeText))
        let coordinator = NotesEditor.Coordinator()
        let editor = NotesTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        editor.note = document
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = document.text
        editor.delegate = coordinator
        coordinator.editor = editor
        let options = Self.options(5)
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            editor.string = Self.largeText
            _ = document.edit(Self.largeText)
            startMeasuring()
            for _ in 0..<200 {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                editor.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            stopMeasuring()
        }
        editor.string = Self.largeText
        _ = document.edit(Self.largeText)
        XCTAssertEqual(document.text, Self.largeText)
    }

    /// P2b: the same typing inside the real SwiftUI notes page, so view updates
    /// (`NotesEditor.updateNSView`, workspace observers) are included. 50 notes exist.
    func testP2bTypingInHostedNotesView() throws {
        _ = NSApplication.shared
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        for index in 0..<50 { XCTAssertTrue(workspace.create().edit("便签 \(index)\n正文")) }
        let document = workspace.create()
        XCTAssertTrue(document.edit(Self.largeText))
        let session = NotesSession(workspace: workspace, document: document)
        let host = NSHostingView(rootView: NotesView(session: session, workspace: workspace, open: { _ in }, export: {}))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 280, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = host
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NotesTextView? {
            (view as? NotesTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let editor = try XCTUnwrap(find(host))
        let options = Self.options(5)
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            editor.string = Self.largeText
            _ = document.edit(Self.largeText)
            host.layoutSubtreeIfNeeded()
            startMeasuring()
            for _ in 0..<100 {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                editor.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
                // Let SwiftUI apply the published change, as the run loop would between keys.
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date())
            }
            stopMeasuring()
        }
        XCTAssertTrue(document.text.hasSuffix("字"))
    }

    /// P3: filter and sort 500 notes of about 2 KB each.
    func testP3ListFiveHundredNotes() throws {
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let body = String(repeating: "今天的会议记录，讨论了排期与验收。\n", count: 40)
        for index in 0..<500 {
            XCTAssertTrue(workspace.create().edit("便签 \(index)\n" + body + (index % 10 == 0 ? "关键字" : "")))
        }
        measure(metrics: [XCTClockMetric()], options: Self.options(10)) {
            XCTAssertEqual(workspace.list(query: "关键字").count, 50)
            XCTAssertEqual(workspace.list().count, 500)
        }
    }
}
