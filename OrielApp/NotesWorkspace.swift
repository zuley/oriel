import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class NoteDocument: ObservableObject, Identifiable {
    @Published private(set) var record: NoteRecord
    @Published private(set) var isPersisted: Bool
    @Published var errorMessage: String?
    private var savedRecord: NoteRecord?
    var changed: (() -> Void)?
    var commitEditing: (() -> Void)?
    let undo = UndoManager()
    var selection = NSRange(location: 0, length: 0)
    var scrollY: CGFloat = 0
    var editorView: NSScrollView?
    nonisolated let id: UUID
    var text: String { record.text }
    var title: String { record.title }
    var isDirty: Bool {
        guard isPersisted else {
            // A draft counts once it has any non-blank character; stop at the first one.
            return text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        guard let saved = savedRecord else { return true }
        // Every edit stamps `updated`, so typing is decided without reading the text.
        return saved.updated != record.updated || saved.pinned != record.pinned
            || saved.deleted != record.deleted || !Self.sameText(saved.text, record.text)
    }
    /// Set by `edit` before `changed` runs: the title or saved state changed, so note lists
    /// and tab titles need a refresh. Ordinary typing inside the body leaves it false.
    private(set) var lastEditChangedListing = false

    init(record: NoteRecord, persisted: Bool) {
        self.id = record.id
        self.record = record
        isPersisted = persisted
        savedRecord = persisted ? record : nil
    }

    @discardableResult func edit(_ text: String) -> Bool {
        guard text.utf8.count <= NoteRecord.textLimit else {
            errorMessage = NotesError.tooLarge.localizedDescription
            return false
        }
        guard !Self.sameText(text, record.text) else { return true }
        let wasDirty = isDirty
        let oldTitle = title
        record.text = text
        record.updated = Date()
        errorMessage = nil
        lastEditChangedListing = wasDirty != isDirty || oldTitle != title
        changed?()
        return true
    }

    /// Exact equality (same code units), not Swift's canonical equivalence: a canonically
    /// equivalent text with different bytes is still a change to save. Editor text is a
    /// bridged NSString; Swift `==` on 1 MiB of it costs about 11 ms and converting it to
    /// native UTF-8 about 19 ms, while this is O(1) for the same object or a different
    /// length and a code-unit comparison otherwise.
    nonisolated static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs as NSString, right = rhs as NSString
        if left === right { return true }
        return left.length == right.length && left.isEqual(to: rhs)
    }

    func releaseEditor() {
        commitEditing?()
        commitEditing = nil
        undo.removeAllActions()
        editorView = nil
    }

    func accept(_ record: NoteRecord) {
        self.record = record
        saved()
    }

    func saved() {
        savedRecord = record
        isPersisted = true
        errorMessage = nil
    }
}

@MainActor
final class NotesWorkspace: ObservableObject {
    static let shared = NotesWorkspace(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "app.oriel.mac").appending(path: "Notes"))
    @Published private(set) var documents: [UUID: NoteDocument] = [:]
    @Published private(set) var loadError: String?
    private let store: NotesStore
    private let automaticSaving: Bool
    private let clock: () -> TimeInterval
    private var firstEdit: TimeInterval?
    private var lastEdit: TimeInterval?
    private var saveTimer: Timer?
    private var saving = false
    private var confirmingClose = false
    var onSaveBlocked: ((Set<UUID>?) -> Void)?

    init(root: URL, automaticSaving: Bool = true, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        store = NotesStore(root: root)
        self.automaticSaving = automaticSaving
        do {
            let loaded = try store.load()
            for record in loaded.records { attach(NoteDocument(record: record, persisted: true)) }
            loadError = loaded.issues.isEmpty ? nil : loaded.issues.joined(separator: "\n")
        } catch { loadError = NotesError.message(error) }
    }

    func create() -> NoteDocument {
        let now = Date()
        let document = NoteDocument(record: .init(id: UUID(), text: "", created: now, updated: now), persisted: false)
        attach(document)
        return document
    }

    func discardEmptyDraft(_ document: NoteDocument) {
        guard !document.isPersisted, !document.isDirty else { return }
        documents.removeValue(forKey: document.id)
        document.changed = nil
    }

    func acknowledgeRecovery() { loadError = nil }

    func revealStorage() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.root.path) }

    func confirmCanClose(documentIDs: Set<UUID>? = nil) -> Bool {
        if documentIDs?.isEmpty == true { return true }
        guard !confirmingClose else { return false }
        confirmingClose = true
        defer { confirmingClose = false }
        while true {
            do {
                if let documentIDs { try saveForClosing(documentIDs) }
                else { try saveAll() }
                return true
            }
            catch {
                onSaveBlocked?(documentIDs)
                let alert = NSAlert()
                alert.window.level = .statusBar
                alert.messageText = "便签尚未保存"
                alert.informativeText = "文字仍在小窗中。可以保留窗口后复制或导出，也可以修复磁盘问题后重试。\n\n" + NotesError.message(error)
                alert.addButton(withTitle: "保留窗口")
                alert.addButton(withTitle: "重试保存")
                if alert.runModal() != .alertSecondButtonReturn { return false }
            }
        }
    }

    private func attach(_ document: NoteDocument) {
        documents[document.id] = document
        document.changed = { [weak self, weak document] in
            guard let self else { return }
            // The editor and its status dot observe the document itself; the workspace
            // (lists, tab titles in every window) only needs title and saved-state changes.
            if document?.lastEditChangedListing != false { objectWillChange.send() }
            firstEdit = firstEdit ?? clock()
            lastEdit = clock()
            scheduleSave()
        }
    }

    func list(query: String = "", trash: Bool = false) -> [NoteDocument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents.values.filter {
            ($0.isPersisted || $0.isDirty) && ($0.record.deleted != nil) == trash &&
            (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.record.pinned != $1.record.pinned { return $0.record.pinned }
            if $0.record.updated != $1.record.updated { return $0.record.updated > $1.record.updated }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func setPinned(_ pinned: Bool, for document: NoteDocument) throws {
        try update(document) { $0.pinned = pinned }
    }

    func trash(_ document: NoteDocument) throws {
        try update(document) { $0.deleted = Date() }
    }

    func restore(_ document: NoteDocument) throws {
        try update(document) { $0.deleted = nil }
    }

    private func update(_ document: NoteDocument, change: (inout NoteRecord) -> Void) throws {
        document.commitEditing?()
        var record = document.record
        change(&record)
        do {
            try store.save(record)
            document.accept(record)
            objectWillChange.send()
        } catch {
            document.errorMessage = NotesError.message(error)
            throw error
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        guard automaticSaving, !saving, let firstEdit, let lastEdit else { return }
        let due = min(lastEdit + 0.3, firstEdit + 2)
        let timer = Timer(timeInterval: max(0.001, due - clock()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.saveIfDue() } catch { /* Keep dirty content; retry on edit or explicit save. */ }
            }
        }
        saveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func saveIfDue() throws {
        guard let firstEdit, let lastEdit else { return }
        if clock() >= min(lastEdit + 0.3, firstEdit + 2) {
            try save(commitEditing: false)
        } else { scheduleSave() }
    }

    func saveAll() throws { try save(commitEditing: true) }

    func saveForClosing(_ documentIDs: Set<UUID>) throws {
        try save(commitEditing: true, documentIDs: documentIDs)
    }

    private func save(commitEditing: Bool, documentIDs: Set<UUID>? = nil) throws {
        if documentIDs?.isEmpty == true { return }
        guard !saving else { return }
        saving = true
        defer {
            saving = false
            // Closing one document must not discard the pending save of another.
            if documentIDs != nil { scheduleSave() }
        }
        saveTimer?.invalidate()
        saveTimer = nil
        let targets = documents.values.filter { documentIDs?.contains($0.id) ?? true }
        if commitEditing { for document in targets { document.commitEditing?() } }
        var failure: Error?
        for document in targets where document.isDirty {
            do { try store.save(document.record); document.saved() }
            catch { document.errorMessage = NotesError.message(error); failure = failure ?? error }
        }
        if documentIDs == nil {
            firstEdit = nil
            lastEdit = nil
        }
        objectWillChange.send()
        if let failure { throw failure }
    }
}

@MainActor
final class NotesSession: ObservableObject {
    let workspace: NotesWorkspace
    @Published var document: NoteDocument
    @Published var showingList = false
    @Published var showingTrash = false
    @Published var query = ""
    @Published var exporting = false
    var choosingNote = false
    private var savePanel: NSSavePanel?
    var focusSearch: (() -> Void)?

    init(workspace: NotesWorkspace = .shared, document: NoteDocument? = nil) {
        self.workspace = workspace
        self.document = document ?? workspace.list().max(by: { $0.record.updated < $1.record.updated }) ?? workspace.create()
    }

    func select(_ document: NoteDocument) {
        self.document.commitEditing?()
        try? workspace.saveAll()
        let previous = self.document
        if previous.id != document.id { previous.releaseEditor() }
        self.document = document
        showingList = false
        showingTrash = false
        query = ""
        if previous.id != document.id { workspace.discardEmptyDraft(previous) }
    }

    func showList() {
        document.commitEditing?()
        try? workspace.saveAll()
        showingList = true
        showingTrash = false
        focusSearch?()
    }

    func export(in window: NSWindow) {
        guard savePanel == nil else { return }
        document.commitEditing?()
        let text = document.text
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = document.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".txt"
        panel.canCreateDirectories = true
        savePanel = panel
        exporting = true
        panel.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do { try Data(text.utf8).write(to: url, options: .atomic) }
                catch { document?.errorMessage = "导出失败：" + NotesError.message(error) }
            }
            self.savePanel = nil
            self.exporting = false
        }
    }

    func dispose() {
        document.releaseEditor()
        savePanel?.cancel(nil)
        savePanel = nil
        workspace.discardEmptyDraft(document)
    }
}
