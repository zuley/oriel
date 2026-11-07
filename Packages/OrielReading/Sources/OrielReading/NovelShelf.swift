import CryptoKit
import Foundation

public struct ShelfBook: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let chapterCount: Int
    public let sourceID: Int?
    public var sourcePage: URL? { sourceID.flatMap { URL(string: "https://www.gutenberg.org/ebooks/\($0)") } }
    public let added: Date
}

public struct NovelImportResult: Sendable {
    public struct Failure: Sendable {
        public let file: URL
        public let reason: String
    }
    public let books: [ShelfBook]
    public let failures: [Failure]
}

public actor NovelShelf {
    private let root: URL
    private let files = FileManager.default
    public init(root: URL) { self.root = root }

    public func books() throws -> [ShelfBook] {
        guard files.fileExists(atPath: root.path) else { return [] }
        let folders = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return folders.compactMap { folder in
            guard let book = try? metadata(at: folder), book.id == folder.lastPathComponent else { return nil }
            return book
        }.sorted { $0.added > $1.added }
    }

    public func add(file: URL) throws -> ShelfBook {
        let granted = file.startAccessingSecurityScopedResource()
        defer { if granted { file.stopAccessingSecurityScopedResource() } }
        return try add(data: Self.readFile(file), name: file.lastPathComponent)
    }

    public func add(files urls: [URL], progress: @Sendable (Int) async -> Void = { _ in }) async throws -> NovelImportResult {
        var books: [ShelfBook] = []
        var seen = Set<String>()
        var failures: [NovelImportResult.Failure] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            await progress(index + 1)
            do {
                let book = try add(file: url)
                if seen.insert(book.id).inserted { books.append(book) }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(.init(file: url, reason: error.localizedDescription)) }
        }
        return .init(books: books, failures: failures)
    }

    public nonisolated static func readFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReadingError.unsupported }
        guard (values.fileSize ?? 0) <= NovelText.limit else { throw ReadingError.oversized }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: 128 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= NovelText.limit - data.count else { throw ReadingError.oversized }
            data.append(chunk)
        }
        return data
    }

    public func add(data: Data, name: String, source: CatalogNovel? = nil) throws -> ShelfBook {
        try Task.checkCancellation()
        guard data.count <= NovelText.limit else { throw ReadingError.oversized }
        let fileName = URL(fileURLWithPath: name)
        let id = source.map { "pg-\($0.id)" } ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let final = root.appending(path: id)
        let exists = files.fileExists(atPath: final.path)
        let prior = exists ? (try? metadata(at: final)).flatMap { $0.id == id ? $0 : nil } : nil
        if let prior {
            do { _ = try chapters(of: prior); return prior }
            catch ReadingError.damaged { /* Rebuild this edition from the supplied original. */ }
        }
        let parsed: ParsedNovel
        switch fileName.pathExtension.lowercased() {
        case "txt":
            if let source {
                // Reject HTML, error pages and accidentally substituted editions.
                let header = String(decoding: data.prefix(8192), as: UTF8.self)
                guard header.localizedCaseInsensitiveContains("[ebook #\(source.id)]") else { throw ReadingError.damaged }
            }
            parsed = try ParsedNovel(title: source?.title, author: source?.author,
                                     chapters: NovelText.chapters(data: data, gutenberg: source != nil))
        case "epub": parsed = try NovelEPUB.read(data)
        default: throw ReadingError.unsupported
        }
        let fallbackTitle = fileName.deletingPathExtension().lastPathComponent
        let book = ShelfBook(id: id, title: prior?.title ?? parsed.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                             author: parsed.author, chapterCount: parsed.chapters.count, sourceID: source?.id, added: prior?.added ?? Date())
        let staging = root.appending(path: ".import-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let encoder = JSONEncoder()
        try encoder.encode(parsed.chapters).write(to: staging.appending(path: "chapters.json"))
        try encoder.encode(book).write(to: staging.appending(path: "book.json"))
        if source != nil { try data.write(to: staging.appending(path: "original.txt")) }
        try Task.checkCancellation()
        if exists { _ = try files.replaceItemAt(final, withItemAt: staging) }
        else { try files.moveItem(at: staging, to: final) }
        return book
    }

    public func chapters(of book: ShelfBook) throws -> [NovelChapter] {
        let folder = try directory(of: book)
        let url = folder.appending(path: "chapters.json")
        guard files.fileExists(atPath: url.path) else { throw ReadingError.damaged }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let chapters = try? JSONDecoder().decode([NovelChapter].self, from: bytes) else { throw ReadingError.damaged }
        guard !chapters.isEmpty, chapters.count == book.chapterCount else { throw ReadingError.damaged }
        return chapters
    }

    public func remove(_ book: ShelfBook) throws { try files.removeItem(at: directory(of: book)) }

    public func original(of book: ShelfBook) throws -> URL { try directory(of: book).appending(path: "original.txt") }

    private func directory(of book: ShelfBook) throws -> URL {
        guard !book.id.isEmpty, book.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ReadingError.damaged
        }
        return root.appending(path: book.id)
    }

    private func metadata(at folder: URL) throws -> ShelfBook {
        try JSONDecoder().decode(ShelfBook.self, from: Data(contentsOf: folder.appending(path: "book.json")))
    }
}
