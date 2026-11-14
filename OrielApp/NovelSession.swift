import AppKit
import Combine
import OrielReading
import UniformTypeIdentifiers

@MainActor
final class NovelLibrary: ObservableObject {
    let shelf: NovelShelf
    let places: ReadingPlaces
    @Published private(set) var books: [ShelfBook] = []
    let removedBook = PassthroughSubject<String, Never>()
    private var revision = 0
    private var lastActiveBookID: String?
    /// Scroll positions not yet written to UserDefaults, newest per book.
    private var pendingPlaces: [String: ReadingPlace] = [:]
    private var placeFlush: Task<Void, Never>?
    private let placeDelay: Duration
    private var terminationObserver: NSObjectProtocol?

    init(root: URL? = nil, defaults: UserDefaults = .standard, placeDelay: Duration = .seconds(1)) {
        places = ReadingPlaces(defaults: defaults)
        self.placeDelay = placeDelay
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        shelf = NovelShelf(root: root ?? support.appending(path: Bundle.main.bundleIdentifier ?? "app.oriel.mac").appending(path: "Books"))
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPlaces() }
        }
    }

    /// Decoded chapters shared by every tab reading the same book. Held weakly: when the
    /// last tab closes the book (about 47 MiB for a 30 MiB text), the copy is released.
    private let openBooks = NSMapTable<NSString, ChapterBox>.strongToWeakObjects()

    final class ChapterBox {
        let chapters: [NovelChapter]
        init(_ chapters: [NovelChapter]) { self.chapters = chapters }
    }

    func chapters(of book: ShelfBook) async throws -> ChapterBox {
        if let open = openBooks.object(forKey: book.id as NSString) { return open }
        let box = ChapterBox(try await shelf.chapters(of: book))
        // Another tab may have finished decoding the same book meanwhile.
        if let open = openBooks.object(forKey: book.id as NSString) { return open }
        openBooks.setObject(box, forKey: book.id as NSString)
        return box
    }

    func invalidateChapters(for book: ShelfBook) {
        openBooks.removeObject(forKey: book.id as NSString)
    }

    /// The latest reading place, including a scroll position not yet written.
    func place(for book: String) -> ReadingPlace {
        pendingPlaces[book] ?? places.place(for: book)
    }

    /// Write every pending scroll position now (closing, hiding, quitting).
    func flushPlaces() {
        placeFlush?.cancel()
        placeFlush = nil
        let pending = pendingPlaces
        pendingPlaces = [:]
        for (book, place) in pending { places.save(book: book, chapter: place.chapter, offset: place.offset) }
    }

    func refresh() async throws {
        revision += 1
        let version = revision
        let result = try await shelf.books()
        if version == revision { books = result }
    }

    func savePlace(book: String, chapter: Int, offset: Int) {
        let previous = place(for: book)
        // Chapter changes, first opens and switching books update shelf order and progress:
        // write them at once. Scrolling within a chapter is written after a pause.
        if lastActiveBookID != book || previous.chapter != chapter || previous.updated == nil {
            pendingPlaces[book] = nil
            places.save(book: book, chapter: chapter, offset: offset)
            lastActiveBookID = book
            objectWillChange.send()
            return
        }
        pendingPlaces[book] = ReadingPlace(chapter: chapter, offset: offset, updated: Date())
        guard placeFlush == nil else { return }
        let delay = placeDelay
        placeFlush = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.placeFlush = nil
            self?.flushPlaces()
        }
    }

    func addMark(book: ShelfBook, chapter: Int, offset: Int, excerpt: String) {
        places.addMark(book: book.id, chapter: chapter, offset: offset, excerpt: excerpt)
        objectWillChange.send()
    }

    func removeMark(book: ShelfBook, mark: ReadingMark) {
        places.removeMark(book: book.id, mark: mark)
        objectWillChange.send()
    }

    var recent: [ShelfBook] {
        books.map { (book: $0, date: place(for: $0.id).updated ?? $0.added) }
            .sorted { $0.date > $1.date }.map(\.book)
    }

    func remove(_ book: ShelfBook) async throws {
        try await shelf.remove(book)
        pendingPlaces[book.id] = nil
        openBooks.removeObject(forKey: book.id as NSString)
        places.remove(book: book.id)
        removedBook.send(book.id)
        try await refresh()
    }
}

@MainActor
final class NovelSession: ObservableObject {
    enum Section { case shelf, reading, contents, bookmarks, search }
    let library: NovelLibrary
    @Published var section: Section = .shelf
    @Published var notice: String?
    @Published private(set) var markConfirmation = false
    private var confirmationTask: Task<Void, Never>?
    @Published private(set) var busy: String?
    var onBookChanged: (() -> Void)?
    @Published private(set) var book: ShelfBook? { didSet { if book?.id != oldValue?.id { onBookChanged?() } } }
    @Published private(set) var chapters: [NovelChapter] = []
    /// Keeps the shared decoded copy alive while this tab shows the book.
    private var openBook: NovelLibrary.ChapterBox?
    @Published private(set) var chapter = 0
    private(set) var offset = 0
    private(set) var highlight: NSRange?
    private var work: Task<Void, Never>?
    private var filePanel: NSOpenPanel?
    private var removalSubscription: AnyCancellable?
    private var openingBookID: String?
    private enum Request { case files([URL]), saved(ShelfBook), replaceLocal(ShelfBook) }
    private var retryRequest: Request?
    var retryTitle: String? {
        switch retryRequest {
        case .replaceLocal: "重新导入"
        case nil: nil
        default: "重试"
        }
    }
    private var initialized = false
    var choosingFile: Bool { filePanel != nil }

    init(library: NovelLibrary) {
        self.library = library
        removalSubscription = library.removedBook.sink { [weak self] id in
            guard let self else { return }
            if openingBookID == id { cancel(); showShelf() }
            else if book?.id == id { showShelf() }
        }
    }

    func start() {
        // Reattaching an existing tab resumes reading even without a scroll event.
        if section == .reading, busy == nil, let book {
            library.savePlace(book: book.id, chapter: chapter, offset: offset)
        }
        guard !initialized else { return }
        initialized = true
        run(label: nil) { [self] in
            try await library.refresh()
            try Task.checkCancellation()
        }
    }

    func importFile(in window: NSWindow, replacing book: ShelfBook? = nil) {
        guard filePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = book?.sourceID == nil ? [.plainText, UTType(filenameExtension: "epub")!] : [.plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = book == nil
        panel.prompt = "导入"
        if let book {
            panel.message = book.sourceID == nil ? "选择导入时的原文件以修复本书" : "选择同版书籍的原始 TXT 文件"
        } else {
            panel.message = "选择 TXT 或 EPUB 小说"
        }
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] result in
            guard let self, let panel, self.filePanel === panel else { return }
            self.filePanel = nil
            if result == .OK { self.openFiles(panel.urls, replacing: book) }
        }
    }

    func openFiles(_ urls: [URL], replacing book: ShelfBook? = nil) {
        guard let first = urls.first else { return }
        run(label: "正在导入", retry: book.map(Request.replaceLocal) ?? .files(urls)) { [self] in
            if let book {
                let repaired = try await library.shelf.replace(file: first, of: book)
                library.invalidateChapters(for: book)
                try await present(repaired)
                return
            }
            if urls.count == 1 {
                let imported = try await library.shelf.add(file: first)
                try await present(imported)
                return
            }
            let result: NovelImportResult
            do {
                result = try await library.shelf.add(files: urls) { [weak self] index in
                    await self?.importProgress(index, total: urls.count)
                }
            } catch is CancellationError {
                // Completed files are already durable. Reconcile just the shared shelf.
                try await library.refresh()
                throw CancellationError()
            }
            try await library.refresh()
            try Task.checkCancellation()
            showShelf()
            if let failure = result.failures.first {
                retryRequest = .files(result.failures.map(\.file))
                notice = "已入架 \(result.books.count) 本，\(result.failures.count) 份失败。\(failure.file.lastPathComponent) · \(failure.reason)"
            } else {
                notice = "已加入书架 · \(result.books.count) 本"
            }
        }
    }

    private func importProgress(_ index: Int, total: Int) {
        if !Task.isCancelled { busy = "正在导入 \(index) / \(total)" }
    }

    func open(_ saved: ShelfBook) {
        run(label: "正在打开", retry: .saved(saved)) { [self] in try await present(saved) }
    }

    private func present(_ saved: ShelfBook) async throws {
        try Task.checkCancellation()
        openingBookID = saved.id
        defer { if !Task.isCancelled { openingBookID = nil } }
        let box = try await library.chapters(of: saved)
        let text = box.chapters
        try await library.refresh()
        try Task.checkCancellation()
        let place = library.place(for: saved.id)
        highlight = nil
        book = saved
        openBook = box
        chapters = text
        chapter = min(place.chapter, text.count - 1)
        offset = min(place.offset, (text[chapter].text as NSString).length)
        section = .reading
        library.savePlace(book: saved.id, chapter: chapter, offset: offset)
    }

    func saveOffset(_ position: Int, bookID: String, index: Int) {
        guard book?.id == bookID, index == chapter, section == .reading, position != offset else { return }
        offset = position
        library.savePlace(book: bookID, chapter: index, offset: position)
    }

    func turn(to index: Int) {
        guard chapters.indices.contains(index), let book else { return }
        highlight = nil
        if index != chapter {
            offset = 0
            chapter = index
            library.savePlace(book: book.id, chapter: index, offset: 0)
        }
        section = .reading
    }

    func jump(to index: Int, offset requested: Int, length: Int = 0) {
        guard chapters.indices.contains(index), let book else { return }
        let count = (chapters[index].text as NSString).length
        offset = min(max(0, requested), count)
        chapter = index
        highlight = length > 0 ? NSRange(location: offset, length: min(length, count - offset)) : nil
        library.savePlace(book: book.id, chapter: index, offset: offset)
        section = .reading
    }

    func markHere() {
        guard let book, chapters.indices.contains(chapter) else { return }
        let text = chapters[chapter].text as NSString
        let start = min(offset, text.length)
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(45, text.length - start)))
        let excerpt = text.substring(with: range).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        library.addMark(book: book, chapter: chapter, offset: start, excerpt: excerpt)
        confirmationTask?.cancel()
        markConfirmation = true
        confirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.markConfirmation = false
        }
    }

    func showShelf() {
        library.flushPlaces()
        book = nil
        chapters = []
        openBook = nil
        section = .shelf
    }

    func remove(_ saved: ShelfBook) {
        run(label: "正在移除") { [self] in
            try await library.remove(saved)
            if book?.id == saved.id { showShelf() }
        }
    }

    func retry(chooseFile: (ShelfBook?) -> Void) {
        switch retryRequest {
        case .files(let urls): openFiles(urls)
        case .saved(let saved): open(saved)
        case .replaceLocal(let book): chooseFile(book)
        case nil: break
        }
    }

    func cancel() {
        openingBookID = nil
        work?.cancel()
        work = nil
        busy = nil
    }

    func dispose() {
        library.flushPlaces()
        cancel()
        onBookChanged = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        removalSubscription?.cancel()
        removalSubscription = nil
        let panel = filePanel
        filePanel = nil
        panel?.cancel(nil)
    }

    private func run(label: String?, retry: Request? = nil, _ action: @escaping @MainActor () async throws -> Void) {
        initialized = true
        cancel()
        retryRequest = nil
        notice = nil
        busy = label
        work = Task { [weak self] in
            do { try await action() }
            catch {
                if !Task.isCancelled {
                    if case ReadingError.damaged = error, case .saved(let book) = retry {
                        self?.retryRequest = .replaceLocal(book)
                    } else { self?.retryRequest = retry }
                    self?.notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            if !Task.isCancelled { self?.busy = nil; self?.work = nil }
        }
    }
}
