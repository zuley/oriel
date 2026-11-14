import CryptoKit
import Foundation

public struct ShelfBook: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let chapterCount: Int
    /// Kept to decode books saved by versions that offered online downloads.
    public let sourceID: Int?
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

    public func replace(file: URL, of book: ShelfBook) throws -> ShelfBook {
        let granted = file.startAccessingSecurityScopedResource()
        defer { if granted { file.stopAccessingSecurityScopedResource() } }
        return try importBook(data: Self.readFile(file), name: file.lastPathComponent, replacing: book)
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

    public func add(data: Data, name: String) throws -> ShelfBook {
        try importBook(data: data, name: name, replacing: nil)
    }

    private func importBook(data: Data, name: String, replacing target: ShelfBook?) throws -> ShelfBook {
        try Task.checkCancellation()
        guard data.count <= NovelText.limit else { throw ReadingError.oversized }
        if let target { _ = try directory(of: target) }
        let fileName = URL(fileURLWithPath: name)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id = target?.id ?? hash
        let final = root.appending(path: id)
        let exists = files.fileExists(atPath: final.path)
        let prior = exists ? (try? metadata(at: final)).flatMap { $0.id == id ? $0 : nil } : nil
        if let target {
            // The metadata file may itself be what is damaged; the folder name is the identity.
            guard exists else { throw ReadingError.damaged }
            if let sourceID = target.sourceID {
                let header = String(decoding: data.prefix(8192), as: UTF8.self)
                guard target.id == "pg-\(sourceID)", fileName.pathExtension.lowercased() == "txt",
                      header.localizedCaseInsensitiveContains("[ebook #\(sourceID)]") else {
                    throw ReadingError.wrongEdition
                }
            } else {
                guard hash == target.id else { throw ReadingError.wrongEdition }
            }
        } else if let prior {
            do { _ = try chapters(of: prior); return prior }
            catch ReadingError.damaged { /* Rebuild this edition from the supplied original. */ }
        }
        let parsed: ParsedNovel
        switch fileName.pathExtension.lowercased() {
        case "txt":
            parsed = try ParsedNovel(title: nil, author: nil,
                                     chapters: NovelText.chapters(data: data, legacyGutenberg: target?.sourceID != nil))
        case "epub": parsed = try NovelEPUB.read(data)
        default: throw ReadingError.unsupported
        }
        let fallbackTitle = fileName.deletingPathExtension().lastPathComponent
        let book = ShelfBook(id: id, title: prior?.title ?? target?.title ?? parsed.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
                             author: target?.author ?? parsed.author, chapterCount: parsed.chapters.count,
                             sourceID: target?.sourceID, added: prior?.added ?? target?.added ?? Date())
        let staging = root.appending(path: ".import-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let encoder = JSONEncoder()
        try encoder.encode(parsed.chapters).write(to: staging.appending(path: "chapters.json"))
        try encoder.encode(book).write(to: staging.appending(path: "book.json"))
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

    public func exportSnapshot(to destination: URL) throws {
        // This synchronous actor turn cannot interleave with a shelf mutation.
        guard files.fileExists(atPath: root.path) else {
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        try validateExportTree(root)
        try files.copyItem(at: root, to: destination)
    }

    private func validateExportTree(_ url: URL) throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw ReadingError.damaged }
        if values.isDirectory == true {
            for item in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateExportTree(item)
            }
        }
    }

    public func remove(_ book: ShelfBook) throws { try files.removeItem(at: directory(of: book)) }

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
