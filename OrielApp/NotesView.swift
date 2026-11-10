import AppKit
import SwiftUI

struct NotesView: View {
    @ObservedObject var session: NotesSession
    @ObservedObject var workspace: NotesWorkspace
    var open: (NoteDocument) -> Void
    var export: () -> Void
    private let accent = OrielPalette.tint

    var body: some View {
        GeometryReader { geometry in
            Group {
            if geometry.size.height < 68 { pocket } else {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    if geometry.size.width < 170 {
                        Menu { menuItems; Divider(); noteChoices } label: {
                            Label(session.showingList ? (session.showingTrash ? "回收站" : "便签") : session.document.title,
                                  systemImage: "note.text").lineLimit(1)
                        }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("便签菜单")
                    } else {
                        icon(session.showingList ? "chevron.left" : "list.bullet", session.showingList ? "返回便签" : "便签列表") {
                            if session.showingList { session.showingList = false }
                            else { session.showList() }
                        }
                        Text(session.showingList ? (session.showingTrash ? "回收站" : "便签") : session.document.title)
                            .fontWeight(.medium).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        icon("plus", "新建便签") { open(workspace.create()) }
                        Menu { menuItems } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("便签操作")
                    }
                    if workspace.loadError != nil {
                        icon("exclamationmark.circle", "便签恢复提示", action: showRecovery).foregroundStyle(Color(nsColor: OrielPalette.amber))
                    }
                    NoteStatus(document: session.document, workspace: workspace).frame(width: 14)
                }.frame(height: 22).padding(.horizontal, 4)
                if session.showingList { list }
                else if session.document.record.deleted != nil {
                    VStack(spacing: 4) {
                        Text("已移到回收站").foregroundStyle(OrielPalette.mutedText)
                        Button("恢复便签") { restore(session.document) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NotesEditor(document: session.document).id(session.document.id)
                }
            }
            }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .font(.system(size: 11)).foregroundStyle(OrielPalette.text).tint(accent).buttonStyle(.plain)
    }

    private var pocket: some View {
        HStack(spacing: 0) {
            Menu { menuItems; Divider(); noteChoices } label: {
                Image(systemName: session.document.errorMessage == nil ? "note.text" : "exclamationmark.circle")
                    .frame(width: 20, height: 22)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("便签菜单")
                .popover(isPresented: $session.showingList, arrowEdge: .bottom) {
                    VStack(spacing: 0) {
                        HStack {
                            Text(session.showingTrash ? "回收站" : "便签").fontWeight(.medium)
                            Spacer()
                            icon("xmark", "关闭便签列表") { session.showingList = false }
                        }.padding(.leading, 7)
                        list
                    }.frame(width: 240, height: 240)
                        .font(.system(size: 11)).buttonStyle(.plain).tint(accent)
                        .onAppear { session.choosingNote = true }
                        .onDisappear { session.choosingNote = false }
                }
            if session.document.record.deleted != nil {
                Button("恢复") { restore(session.document) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NotesEditor(document: session.document, compact: true).id(session.document.id)
            }
        }
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .accessibilityLabel(label).help(label)
    }

    @ViewBuilder private var menuItems: some View {
        if let error = session.document.errorMessage {
            if session.document.isDirty { Button("重试保存") { try? workspace.saveAll() } }
            Button("查看错误") {
                let alert = NSAlert()
                alert.window.level = .statusBar
                alert.messageText = session.document.isDirty ? "未保存" : "操作未完成"
                alert.informativeText = error
                alert.runModal()
            }
            Divider()
        }
        Button("新建便签") { open(workspace.create()) }
        Button("列表与搜索") { session.showList() }
        if session.showingList { Button("返回正文") { session.showingList = false } }
        Divider()
        if session.document.record.deleted == nil {
            Button(session.document.record.pinned ? "取消置顶" : "置顶") {
                try? workspace.setPinned(!session.document.record.pinned, for: session.document)
            }.disabled(!session.document.isPersisted && !session.document.isDirty)
            Button("导出 TXT", action: export)
            Button("复制全文") { copy() }
            Button("移到回收站") {
                do { try workspace.trash(session.document); session.showingList = true; session.showingTrash = false }
                catch { /* The document presents its save error. */ }
            }.disabled(!session.document.isPersisted && !session.document.isDirty)
        } else {
            Button("恢复便签") { restore(session.document) }
            Button("复制全文") { copy() }
        }
        Divider()
        Button(session.showingTrash ? "全部便签" : "回收站") {
            session.showingList = true; session.showingTrash.toggle(); session.query = ""
        }
        if workspace.loadError != nil {
            Button("查看恢复提示") { showRecovery() }
        }
    }

    @ViewBuilder private var noteChoices: some View {
        Menu("切换便签") {
            ForEach(workspace.list()) { document in
                Button((document.record.pinned ? "⌃ " : "") + document.title) { open(document) }
            }
            if workspace.list().isEmpty { Text("暂无便签") }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass").foregroundStyle(OrielPalette.mutedText)
                NotesSearch(session: session, submit: {
                    if let first = workspace.list(query: session.query, trash: session.showingTrash).first {
                        if session.showingTrash { restore(first) } else { open(first) }
                    }
                }).frame(height: 20)
                if !session.query.isEmpty {
                    icon("xmark.circle.fill", "清除搜索") { session.query = "" }
                }
            }.padding(.horizontal, 6).frame(height: 24)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if workspace.loadError != nil {
                        Button("有恢复提示 · 查看") { showRecovery() }
                            .foregroundStyle(Color(nsColor: OrielPalette.amber)).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    let documents = workspace.list(query: session.query, trash: session.showingTrash)
                    ForEach(documents) { document in
                        Button {
                            if session.showingTrash { restore(document) } else { open(document) }
                        } label: {
                            HStack(spacing: 5) {
                                if document.record.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(accent) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(preview(document)).font(.system(size: 10)).foregroundStyle(OrielPalette.mutedText).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let error = document.errorMessage {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: OrielPalette.amber)).help(error)
                                }
                                Image(systemName: session.showingTrash ? "arrow.uturn.backward" : "chevron.right")
                                    .font(.system(size: 9)).foregroundStyle(OrielPalette.mutedText)
                            }.padding(.horizontal, 6).padding(.vertical, 7).contentShape(Rectangle())
                        }.accessibilityLabel(session.showingTrash ? "恢复：" + document.title : document.title)
                        .contextMenu {
                            if session.showingTrash { Button("恢复") { restore(document) } }
                            else {
                                Button(document.record.pinned ? "取消置顶" : "置顶") { try? workspace.setPinned(!document.record.pinned, for: document) }
                                Button("移到回收站") { try? workspace.trash(document) }
                            }
                        }
                    }
                    if documents.isEmpty {
                        VStack(spacing: 5) {
                            Text(session.query.isEmpty ? (session.showingTrash ? "回收站为空" : "还没有便签") : "没有匹配的便签").foregroundStyle(OrielPalette.mutedText)
                            if !session.query.isEmpty { Button("清除搜索") { session.query = "" } }
                            else if !session.showingTrash { Button("新建便签") { open(workspace.create()) } }
                        }.padding(8).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func preview(_ document: NoteDocument) -> String {
        let lines = document.text.split(whereSeparator: \.isNewline)
        return lines.dropFirst().first.map(String.init) ?? (document.text.isEmpty ? "空白便签" : "")
    }

    private func restore(_ document: NoteDocument) {
        do { try workspace.restore(document); open(document) }
        catch { /* The document retains its state and error. */ }
    }

    private func copy() {
        session.document.commitEditing?()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.document.text, forType: .string)
    }

    private func showRecovery() {
        let alert = NSAlert()
        alert.window.level = .statusBar
        alert.messageText = "便签恢复提示"
        alert.informativeText = workspace.loadError ?? ""
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "打开存储目录")
        if alert.runModal() == .alertSecondButtonReturn { workspace.revealStorage() }
        workspace.acknowledgeRecovery()
    }
}

private struct NoteStatus: View {
    @ObservedObject var document: NoteDocument
    let workspace: NotesWorkspace
    @State private var details = false
    var body: some View {
        ZStack {
            if let error = document.errorMessage {
                Button { details = true } label: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: OrielPalette.amber)).frame(width: 18, height: 22) }
                    .accessibilityLabel(document.isDirty ? "未保存" : "操作未完成").help(error)
                    .popover(isPresented: $details) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(document.isDirty ? "未保存" : "操作未完成").fontWeight(.medium)
                            Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            if document.isDirty {
                                Button("重试保存") { do { try workspace.saveAll(); details = false } catch {} }
                            } else {
                                Button("知道了") { document.errorMessage = nil; details = false }
                            }
                        }.padding(10).frame(width: 210)
                    }
            } else if document.isDirty {
                Circle().fill(.secondary).frame(width: 4, height: 4).padding(.horizontal, 5).help("尚未保存")
            }
        }
    }
}

/// Uses AppKit's text input and undo system; no string round-trip during marked-text composition.
struct NotesEditor: NSViewRepresentable {
    @ObservedObject var document: NoteDocument
    var compact = false

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.syncedText = document.text
        if let scroll = document.editorView, let editor = scroll.documentView as? NotesTextView {
            editor.compact = compact
            editor.delegate = context.coordinator
            context.coordinator.editor = editor
            document.commitEditing = { [weak editor] in editor?.commit() }
            return scroll
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NotesTextView(frame: scroll.bounds)
        editor.note = document
        editor.compact = compact
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = OrielPalette.ink
        editor.insertionPointColor = OrielPalette.accent
        editor.selectedTextAttributes = [.backgroundColor: OrielPalette.textSelection, .foregroundColor: OrielPalette.ink]
        editor.textContainerInset = NSSize(width: compact ? 3 : 6, height: compact ? 2 : 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.string = document.text
        editor.setAccessibilityLabel("便签正文")
        let length = (document.text as NSString).length
        let start = min(document.selection.location, length)
        editor.setSelectedRange(NSRange(location: start, length: min(document.selection.length, length - start)))
        scroll.documentView = editor
        document.editorView = scroll
        context.coordinator.editor = editor
        document.commitEditing = { [weak editor] in editor?.commit() }
        DispatchQueue.main.async { [weak scroll, weak editor] in
            guard let scroll, let editor else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(self.document.scrollY, editor.bounds.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NotesTextView else { return }
        editor.compact = compact
        editor.textContainerInset = NSSize(width: compact ? 3 : 6, height: compact ? 2 : 6)
        // Runs on every keystroke (the document is observed). Typing already put the
        // model's text in `syncedText`, so this is a byte comparison of the same buffer;
        // the editor is read only when the text was replaced from outside.
        guard !editor.hasMarkedText(), !NoteDocument.sameText(document.text, context.coordinator.syncedText) else { return }
        context.coordinator.syncedText = document.text
        if !NoteDocument.sameText(editor.string, document.text) { editor.string = document.text }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = coordinator.editor, editor.delegate === coordinator else { return }
        editor.commit()
        editor.note?.commitEditing = nil
        editor.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var editor: NotesTextView?
        /// The model text last known to match the editor.
        var syncedText = ""
        func textDidChange(_ notification: Notification) {
            guard let editor, !editor.hasMarkedText(), let note = editor.note else { return }
            if note.edit(editor.string) { syncedText = note.text }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor else { return }
            editor.note?.selection = editor.selectedRange()
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, let note = editor?.note else { return true }
            let text = textView.string as NSString
            guard affectedCharRange.location <= text.length, affectedCharRange.length <= text.length - affectedCharRange.location else { return false }
            let candidate = text.replacingCharacters(in: affectedCharRange, with: replacementString)
            guard candidate.utf8.count > NoteRecord.textLimit else { return true }
            note.errorMessage = NotesError.tooLarge.localizedDescription
            NSSound.beep()
            return false
        }
    }
}

final class NotesTextView: NSTextView {
    weak var note: NoteDocument?
    /// The pocket layout (under 68 pt high), where a find bar does not fit.
    var compact = false
    override var undoManager: UndoManager? { note?.undo }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let point = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        ("开始记录…" as NSString).draw(at: point, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: OrielPalette.secondary
        ])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", modifiers == .command || modifiers == [.command, .shift] {
            if hasMarkedText() { unmarkText() }
            breakUndoCoalescing()
            if modifiers.contains(.shift) { if undoManager?.canRedo == true { undoManager?.redo() } }
            else if undoManager?.canUndo == true { undoManager?.undo() }
            return true
        }
        if modifiers == .command {
            switch key {
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": pasteAsPlainText(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !window.ignoresMouseEvents else { return }
            window.makeFirstResponder(self)
        }
    }
    func commit() {
        if hasMarkedText() { unmarkText() }
        _ = note?.edit(string)
        note?.selection = selectedRange()
        note?.scrollY = enclosingScrollView?.contentView.bounds.minY ?? 0
    }
    override func resignFirstResponder() -> Bool {
        commit()
        return super.resignFirstResponder()
    }
}

private struct NotesSearch: NSViewRepresentable {
    @ObservedObject var session: NotesSession
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(session: session, submit: submit) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NoteSearchField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = "搜索便签"
        field.setAccessibilityLabel("搜索便签")
        field.delegate = context.coordinator
        session.focusSearch = { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.submit = submit
        if field.stringValue != session.query { field.stringValue = session.query }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let session: NotesSession
        var submit: () -> Void
        init(session: NotesSession, submit: @escaping () -> Void) { self.session = session; self.submit = submit }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { session.query = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if session.query.isEmpty { session.showingList = false } else { session.query = "" }
                return true
            }
            return false
        }
    }
}

private final class NoteSearchField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}
