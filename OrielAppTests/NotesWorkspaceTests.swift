import XCTest
import SwiftUI

@MainActor
final class NotesWorkspaceTests: XCTestCase {
    func testClosingOnlyOwnedNotesIgnoresOtherSaveFailures() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let a = workspace.create()
        let b = workspace.create()
        a.edit("A 原文"); b.edit("B 原文")
        try workspace.saveAll()
        let blockedBackup = root.appending(path: a.id.uuidString + ".json.backup")
        try FileManager.default.createDirectory(at: blockedBackup, withIntermediateDirectories: false)
        a.edit("A 未保存"); b.edit("B 最新正文")
        XCTAssertNoThrow(try workspace.saveForClosing([]))
        XCTAssertNoThrow(try workspace.saveForClosing([b.id]))
        XCTAssertTrue(a.isDirty)
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(NotesWorkspace(root: root).documents[b.id]?.text, "B 最新正文")
        XCTAssertThrowsError(try workspace.saveForClosing([a.id]))
        XCTAssertEqual(a.text, "A 未保存")
        XCTAssertTrue(a.isDirty)
        XCTAssertNoThrow(try workspace.saveForClosing([b.id]))
        XCTAssertThrowsError(try workspace.saveAll()) // Application quit still checks every note.
        try FileManager.default.removeItem(at: blockedBackup)
        try workspace.saveForClosing([a.id])
        XCTAssertEqual(NotesWorkspace(root: root).documents[a.id]?.text, "A 未保存")
    }

    func testClosingOneNotePreservesOtherNotesAutosaveDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now: TimeInterval = 100
        let workspace = NotesWorkspace(root: root, automaticSaving: false, clock: { now })
        let a = workspace.create()
        let b = workspace.create()
        a.edit("另一窗口已提交的正文")
        b.edit("待关闭的正文")
        now = 100.1
        try workspace.saveForClosing([b.id])
        XCTAssertTrue(a.isDirty)
        XCTAssertFalse(b.isDirty)
        now = 100.31
        try workspace.saveIfDue()
        XCTAssertEqual(NotesWorkspace(root: root).documents[a.id]?.text, "另一窗口已提交的正文")
        XCTAssertFalse(a.isDirty)
    }

    func testTitlesKeepUnicodeBlankLinesAndTruncationRulesForLargeNotes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let note = workspace.create()
        note.edit("  \r\n\t\n  阅读 👨‍👩‍👧‍👦  \r\n" + String(repeating: "正文\n", count: 100_000))
        XCTAssertEqual(note.title, "阅读 👨‍👩‍👧‍👦")
        note.edit(String(repeating: "👨‍👩‍👧‍👦", count: 40) + "   \n下一行")
        XCTAssertEqual(note.title, String(repeating: "👨‍👩‍👧‍👦", count: 40))
        note.edit(String(repeating: "中", count: 41) + "\n正文")
        XCTAssertEqual(note.title, String(repeating: "中", count: 40) + "…")
        note.edit(" \t\r\n  ")
        XCTAssertEqual(note.title, "未命名")
    }

    func testTypingAndSavingRestoresExactUnicodeTextInANewWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let note = workspace.create()
        XCTAssertTrue(workspace.list().isEmpty)
        let text = "周末计划\n买咖啡 ☕️\n中文拼音与 emoji 👨‍👩‍👧‍👦\n"
        XCTAssertTrue(note.edit(text))
        try workspace.saveAll()
        let reopened = NotesWorkspace(root: root, automaticSaving: false)
        let restored = try XCTUnwrap(reopened.list().first)
        XCTAssertEqual(restored.id, note.id)
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.title, "周末计划")
        XCTAssertFalse(restored.isDirty)
    }
    func testOrganizingNotesPersistsPinTrashAndRestoreWithoutChangingIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let first = workspace.create()
        first.edit("咖啡清单\nArabica 豆子")
        let second = workspace.create()
        second.edit("明天安排")
        try workspace.saveAll()
        try workspace.setPinned(true, for: first)
        XCTAssertEqual(workspace.list().map(\.id), [first.id, second.id])
        XCTAssertEqual(workspace.list(query: "ARABICA").map(\.id), [first.id])
        try workspace.trash(first)
        XCTAssertEqual(workspace.list().map(\.id), [second.id])
        let reopened = NotesWorkspace(root: root, automaticSaving: false)
        let deleted = try XCTUnwrap(reopened.list(trash: true).first)
        XCTAssertEqual(deleted.text, "咖啡清单\nArabica 豆子")
        try reopened.restore(deleted)
        let restored = NotesWorkspace(root: root, automaticSaving: false)
        XCTAssertEqual(restored.list().first?.id, first.id)
        XCTAssertTrue(try XCTUnwrap(restored.list().first).record.pinned)
        XCTAssertTrue(restored.list(trash: true).isEmpty)
    }
    func testAutosaveCoalescesTypingButSavesContinuousInputWithinTwoSeconds() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now: TimeInterval = 100
        let workspace = NotesWorkspace(root: root, automaticSaving: false, clock: { now })
        let note = workspace.create()
        note.edit("一")
        now = (100.2)
        try workspace.saveIfDue()
        XCTAssertTrue(NotesWorkspace(root: root).list().isEmpty)
        now = (100.31)
        try workspace.saveIfDue()
        XCTAssertEqual(NotesWorkspace(root: root).list().first?.text, "一")
        for step in 0..<10 {
            now = (101 + Double(step) * 0.2)
            note.edit("连续输入 \(step)")
            try workspace.saveIfDue()
        }
        XCTAssertEqual(NotesWorkspace(root: root).list().first?.text, "一")
        now = (103)
        note.edit("连续输入完成")
        try workspace.saveIfDue()
        XCTAssertEqual(NotesWorkspace(root: root).list().first?.text, "连续输入完成")
        XCTAssertFalse(note.isDirty)
    }
    func testCorruptNoteRecoversPreviousVersionAndDoesNotHideOtherNotes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let note = workspace.create()
        note.edit("上一份完整内容")
        try workspace.saveAll()
        note.edit("最新完整内容")
        let other = workspace.create()
        other.edit("另一张仍然可读")
        try workspace.saveAll()
        let broken = root.appending(path: note.id.uuidString + ".json")
        try Data("broken original".utf8).write(to: broken)
        let reopened = NotesWorkspace(root: root, automaticSaving: false)
        XCTAssertEqual(reopened.documents[note.id]?.text, "上一份完整内容")
        XCTAssertEqual(reopened.documents[other.id]?.text, "另一张仍然可读")
        XCTAssertNotNil(reopened.loadError)
        // Recovery must preserve the broken evidence before any subsequent save.
        let recovery = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first)), Data("broken original".utf8))
        reopened.documents[note.id]?.edit("恢复后继续输入")
        try reopened.saveAll()
        XCTAssertEqual(NotesWorkspace(root: root).documents[note.id]?.text, "恢复后继续输入")
    }
    func testFailedSaveKeepsLatestTextDirtyAndRetryRestoresIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let displaced = root.appendingPathExtension("old")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: displaced) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let note = workspace.create()
        note.edit("旧版本")
        try workspace.saveAll()
        try FileManager.default.moveItem(at: root, to: displaced)
        try Data().write(to: root) // A file where the directory was reliably prevents writes.
        note.edit("未保存的中文 ✨")
        XCTAssertThrowsError(try workspace.saveAll())
        XCTAssertTrue(note.isDirty)
        XCTAssertNotNil(note.errorMessage)
        XCTAssertEqual(note.text, "未保存的中文 ✨")
        XCTAssertEqual(NotesWorkspace(root: displaced).documents[note.id]?.text, "旧版本")
        XCTAssertThrowsError(try workspace.trash(note))
        XCTAssertNil(note.record.deleted)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: displaced, to: root)
        try workspace.saveAll()
        XCTAssertFalse(note.isDirty)
        XCTAssertNil(note.errorMessage)
        XCTAssertEqual(NotesWorkspace(root: root).documents[note.id]?.text, "未保存的中文 ✨")
    }

    func testUnknownVersionIsPreservedAndEmptySavedNotesRemainRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let note = workspace.create()
        note.edit("原有内容")
        try workspace.saveAll()
        note.edit("")
        try workspace.saveAll()
        XCTAssertEqual(NotesWorkspace(root: root).documents[note.id]?.text, "")
        let draft = workspace.create()
        draft.edit("  \n")
        try workspace.saveAll()
        XCTAssertEqual(NotesWorkspace(root: root).list().count, 1)
        let futureID = UUID()
        let futureURL = root.appending(path: futureID.uuidString + ".json")
        let future = Data("{\"schema\":900,\"unknown\":\"do not change\"}".utf8)
        try future.write(to: futureURL)
        let reopened = NotesWorkspace(root: root)
        XCTAssertEqual(reopened.list().count, 1)
        XCTAssertNotNil(reopened.loadError)
        try reopened.saveAll()
        XCTAssertEqual(try Data(contentsOf: futureURL), future)
        XCTAssertFalse(note.edit(String(repeating: "中", count: 400_000)))
        XCTAssertEqual(note.text, "")
    }
    func testNativeEditorCommitsMarkedTextAndSupportsUndoAndRedo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        let hosting = NSHostingView(rootView: NotesEditor(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func textView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        let editor = try XCTUnwrap(textView(hosting))
        window.makeFirstResponder(editor)
        document.undo.groupsByEvent = false
        document.undo.beginUndoGrouping()
        editor.setMarkedText("中文拼音", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        try workspace.saveAll()
        document.undo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(NotesWorkspace(root: root).documents[document.id]?.text, "中文拼音")
        editor.breakUndoCoalescing()
        document.undo.beginUndoGrouping()
        editor.insertText(" 测试", replacementRange: NSRange(location: NSNotFound, length: 0))
        document.undo.endUndoGrouping()
        let undo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(editor.performKeyEquivalent(with: undo))
        XCTAssertEqual(editor.string, "中文拼音")
        let redo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "Z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(editor.performKeyEquivalent(with: redo))
        XCTAssertEqual(editor.string, "中文拼音 测试")
        try workspace.saveAll()
        XCTAssertEqual(NotesWorkspace(root: root).documents[document.id]?.text, "中文拼音 测试")
        window.contentView = nil
        document.releaseEditor()
    }
    func testAutosaveDoesNotInterruptAnInProgressInputMethodComposition() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now: TimeInterval = 100
        let workspace = NotesWorkspace(root: root, automaticSaving: false, clock: { now })
        let document = workspace.create()
        let hosting = NSHostingView(rootView: NotesEditor(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func textView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        let editor = try XCTUnwrap(textView(hosting))
        window.makeFirstResponder(editor)
        editor.insertText("开头", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        now = (100.4)
        try workspace.saveIfDue()
        XCTAssertTrue(editor.hasMarkedText(), "Background saving must not choose or dismiss an IME candidate.")
        XCTAssertEqual(NotesWorkspace(root: root).documents[document.id]?.text, "开头")
        try workspace.saveAll()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(NotesWorkspace(root: root).documents[document.id]?.text, "开头中文")
        window.contentView = nil
        document.releaseEditor()
    }
    func testNativeEditorRejectsOversizedUnicodeWithoutChangingTextOrSelection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        document.edit("安全内容")
        let hosting = NSHostingView(rootView: NotesEditor(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func textView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(textView).first
        }
        let editor = try XCTUnwrap(textView(hosting))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText(String(repeating: "😀", count: 262_145), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "安全内容")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertNotNil(document.errorMessage)
        try workspace.saveAll()
        XCTAssertEqual(NotesWorkspace(root: root).documents[document.id]?.text, "安全内容")
        window.contentView = nil
        document.releaseEditor()
    }
}

// R02: per-keystroke cost (docs/plans/017-refactor-tasks.md).
extension NotesWorkspaceTests {
    func testEditTreatsCanonicallyEquivalentButDifferentBytesAsAChange() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        document.edit("caf\u{E9}")
        try workspace.saveAll()
        // Same text to Unicode's eyes, different bytes on disk: the saved file must follow the editor.
        XCTAssertTrue(document.edit("cafe\u{301}"))
        XCTAssertTrue(document.isDirty)
        try workspace.saveAll()
        let restored = try XCTUnwrap(NotesWorkspace(root: root).documents[document.id])
        XCTAssertTrue(restored.text.utf8.elementsEqual("cafe\u{301}".utf8))
    }

    func testEditingWithABridgedEditorStringIsANoOpWhenUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        document.edit("标题\n正文")
        try workspace.saveAll()
        var changes = 0
        let previous = document.changed
        document.changed = { changes += 1; previous?() }
        let bridged = NSMutableString(string: "标题\n正文") as String
        XCTAssertTrue(document.edit(bridged))
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(document.isDirty)
    }

    func testWorkspaceAnnouncesOnlyTitleAndSavedStateChangesWhileTyping() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        var announcements = 0
        let subscription = workspace.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }
        let document = workspace.create()
        announcements = 0

        document.edit("购")                    // empty draft gains content: becomes listed
        XCTAssertEqual(announcements, 1)
        document.edit("购物")                  // title changes
        XCTAssertEqual(announcements, 2)
        document.edit("购物\n")                 // title unchanged
        document.edit("购物\n牛")
        document.edit("购物\n牛奶")
        XCTAssertEqual(announcements, 2)

        try workspace.saveAll()
        announcements = 0
        document.edit("购物\n牛奶 鸡蛋")         // saved note becomes dirty
        XCTAssertEqual(announcements, 1)
        document.edit("购物\n牛奶 鸡蛋 面包")
        XCTAssertEqual(announcements, 1)
    }

    func testHostedEditorFollowsTextReplacedOutsideTheEditor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = NotesWorkspace(root: root, automaticSaving: false)
        let document = workspace.create()
        document.edit("原文")
        let hosting = NSHostingView(rootView: NotesEditor(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func textView(_ view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textView).first
        }
        let editor = try XCTUnwrap(textView(hosting))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("加字", replacementRange: NSRange(location: NSNotFound, length: 0))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, "原文加字")
        XCTAssertEqual(document.text, "原文加字")

        var record = document.record
        record.text = "外部替换"
        document.accept(record)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        XCTAssertEqual(editor.string, "外部替换")
        window.contentView = nil
        document.releaseEditor()
    }
}

// R01: lighter note saves (docs/plans/017-refactor-tasks.md).
extension NotesWorkspaceTests {
    private func record(_ id: UUID, _ text: String) -> NoteRecord {
        NoteRecord(id: id, text: text, created: Date(timeIntervalSince1970: 1), updated: Date())
    }

    func testBackupHoldsThePreviousVersionAfterEachSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let id = UUID()
        try store.save(record(id, "第一版"))
        try store.save(record(id, "第二版"))
        try store.save(record(id, "第三版"))
        let primary = root.appending(path: id.uuidString + ".json")
        let backup = primary.appendingPathExtension("backup")
        let decode = { (url: URL) in try JSONDecoder().decode(NoteRecord.self, from: Data(contentsOf: url)).text }
        XCTAssertEqual(try decode(primary), "第三版")
        XCTAssertEqual(try decode(backup), "第二版")
        // The backup must be its own file, not a link that later writes could reach.
        let inode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
        XCTAssertNotEqual(try inode(primary), try inode(backup))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") },
                       "No temporary backup links may be left behind.")
    }

    func testRepeatedSavesOfAKnownFileSkipTheReadBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let id = UUID()
        try store.save(record(id, "一"))
        try store.save(record(id, "二"))
        try store.save(record(id, "三"))
        XCTAssertEqual(store.verificationReads, 0, "Files this store wrote need no read-back.")

        let reloaded = NotesStore(root: root)
        _ = try reloaded.load()
        try reloaded.save(record(id, "四"))
        XCTAssertEqual(reloaded.verificationReads, 0, "Files this store loaded need no read-back.")
    }

    func testExternallyChangedPrimaryIsVerifiedAgainAndCorruptionKeepsTheBackup() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let id = UUID()
        try store.save(record(id, "原始"))
        try store.save(record(id, "可靠版本"))
        let primary = root.appending(path: id.uuidString + ".json")
        let backup = primary.appendingPathExtension("backup")
        let backupBytes = try Data(contentsOf: backup)
        try Data("{ broken".utf8).write(to: primary)
        XCTAssertThrowsError(try store.save(record(id, "新内容")))
        XCTAssertEqual(store.verificationReads, 1)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes, "A corrupt primary must never replace the backup.")
    }
}
