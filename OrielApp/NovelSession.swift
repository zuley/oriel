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

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        places = ReadingPlaces(defaults: defaults)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        shelf = NovelShelf(root: root ?? support.appending(path: Bundle.main.bundleIdentifier ?? "app.oriel.mac").appending(path: "Books"))
    }

    func refresh() async throws {
        revision += 1
        let version = revision
        let result = try await shelf.books()
        if version == revision { books = result }
    }

    func savePlace(book: String, chapter: Int, offset: Int) {
        let previous = places.place(for: book)
        places.save(book: book, chapter: chapter, offset: offset)
        // The manager needs chapter/recent-order changes, not a redraw per scroll tick.
        if lastActiveBookID != book || previous.chapter != chapter || previous.updated == nil {
            lastActiveBookID = book
            objectWillChange.send()
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
        books.map { (book: $0, date: places.place(for: $0.id).updated ?? $0.added) }
            .sorted { $0.date > $1.date }.map(\.book)
    }

    func remove(_ book: ShelfBook) async throws {
        try await shelf.remove(book)
        places.remove(book: book.id)
        removedBook.send(book.id)
        try await refresh()
    }
}

@MainActor
final class NovelSession: ObservableObject {
    enum Section { case shelf, catalog, reading, contents, bookmarks, search }
    let library: NovelLibrary
    @Published var section: Section = .shelf
    @Published var notice: String?
    @Published private(set) var markConfirmation = false
    private var confirmationTask: Task<Void, Never>?
    @Published private(set) var busy: String?
    var onBookChanged: (() -> Void)?
    @Published private(set) var book: ShelfBook? { didSet { if book?.id != oldValue?.id { onBookChanged?() } } }
    @Published private(set) var chapters: [NovelChapter] = []
    @Published private(set) var chapter = 0
    private(set) var offset = 0
    private(set) var highlight: NSRange?
    private var work: Task<Void, Never>?
    private var filePanel: NSOpenPanel?
    private var removalSubscription: AnyCancellable?
    private var openingBookID: String?
    private enum Request { case files([URL]), catalog(CatalogNovel), saved(ShelfBook), replaceLocal, replaceOnline(CatalogNovel) }
    private var retryRequest: Request?
    var retryTitle: String? {
        switch retryRequest {
        case .replaceLocal: "重新导入"
        case .replaceOnline: "重新下载"
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
            if library.books.isEmpty { section = .catalog }
        }
    }

    func importFile(in window: NSWindow) {
        guard filePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "epub")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        panel.message = "选择 TXT 或 EPUB 小说"
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] result in
            guard let self, let panel, self.filePanel === panel else { return }
            self.filePanel = nil
            if result == .OK { self.openFiles(panel.urls) }
        }
    }

    func openFiles(_ urls: [URL]) {
        guard let first = urls.first else { return }
        run(label: "正在导入", retry: .files(urls)) { [self] in
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

    func open(_ source: CatalogNovel, fetchAgain: Bool = false) {
        run(label: "正在获取《\(source.title)》", retry: fetchAgain ? .replaceOnline(source) : .catalog(source)) { [self] in
            let saved = try await NovelCatalogLoader(shelf: library.shelf).open(source, fetchAgain: fetchAgain)
            try await present(saved)
        }
    }

    func open(_ saved: ShelfBook) {
        run(label: "正在打开", retry: .saved(saved)) { [self] in try await present(saved) }
    }

    private func present(_ saved: ShelfBook) async throws {
        try Task.checkCancellation()
        openingBookID = saved.id
        defer { if !Task.isCancelled { openingBookID = nil } }
        let text = try await library.shelf.chapters(of: saved)
        try await library.refresh()
        try Task.checkCancellation()
        let place = library.places.place(for: saved.id)
        highlight = nil
        book = saved
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
        book = nil
        chapters = []
        section = .shelf
    }

    func remove(_ saved: ShelfBook) {
        run(label: "正在移除") { [self] in
            try await library.remove(saved)
            if book?.id == saved.id { showShelf() }
        }
    }

    func showOriginal() {
        guard let book else { return }
        run(label: nil) { [self] in
            let url = try await library.shelf.original(of: book)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func retry(chooseFile: () -> Void) {
        switch retryRequest {
        case .files(let urls): openFiles(urls)
        case .catalog(let source): open(source)
        case .saved(let saved): open(saved)
        case .replaceLocal: chooseFile()
        case .replaceOnline(let source): open(source, fetchAgain: true)
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
                    if case ReadingError.damaged = error, case let .saved(book) = retry {
                        self?.retryRequest = CatalogNovel.edition(of: book).map(Request.replaceOnline) ?? .replaceLocal
                    } else if case ReadingError.damaged = error, case let .catalog(source) = retry {
                        self?.retryRequest = .replaceOnline(source)
                    } else { self?.retryRequest = retry }
                    self?.notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            if !Task.isCancelled { self?.busy = nil; self?.work = nil }
        }
    }
}

@MainActor
final class CatalogDiscovery: ObservableObject {
    @Published private(set) var results: [CatalogNovel] = []
    @Published private(set) var searching = false
    @Published private(set) var searched = false
    @Published private(set) var failed = false
    @Published private(set) var next: Int?
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        results = []
        searching = false
        searched = false
        failed = false
        next = nil
    }

    func search(_ query: String, from start: Int = 1) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if start == 1 { reset() }
        task?.cancel()
        searching = true
        failed = false
        task = Task { [weak self] in
            do {
                let page = try await CatalogSearch.search(query, start: start)
                guard let self, !Task.isCancelled else { return }
                let seen = Set(results.map(\.id))
                results += page.books.filter { !seen.contains($0.id) }
                next = page.next.flatMap { $0 > start ? $0 : nil }
                searched = true
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed = true
            }
            self?.searching = false
            self?.task = nil
        }
    }
}
