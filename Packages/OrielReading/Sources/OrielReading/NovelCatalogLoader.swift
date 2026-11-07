import Foundation
import os

public struct NovelCatalogLoader: Sendable {
    private let shelf: NovelShelf
    private let fetch: @Sendable (URL) async throws -> Data

    public init(shelf: NovelShelf, fetch: @escaping @Sendable (URL) async throws -> Data = NovelCatalogLoader.download) {
        self.shelf = shelf
        self.fetch = fetch
    }

    public func open(_ source: CatalogNovel, fetchAgain: Bool = false) async throws -> ShelfBook {
        try Task.checkCancellation()
        if !fetchAgain, let cached = try await shelf.books().first(where: { $0.sourceID == source.id }) { return cached }
        var contentError: ReadingError?
        for url in source.mirrors {
            try Task.checkCancellation()
            let data: Data
            do { data = try await fetch(url) }
            catch ReadingError.oversized { contentError = .oversized; continue }
            catch { try Task.checkCancellation(); continue }
            do { return try await shelf.add(data: data, name: "\(source.id).txt", source: source) }
            catch let error as ReadingError { contentError = error }
        }
        try Task.checkCancellation()
        throw contentError ?? ReadingError.online
    }

    public static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Oriel Reader (github.com/zuley/oriel)", forHTTPHeaderField: "User-Agent")
        let limit = BookDownloadLimit()
        let local: URL
        let response: URLResponse
        do { (local, response) = try await session.download(for: request, delegate: limit) }
        catch {
            if limit.exceeded { throw ReadingError.oversized }
            throw error
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ReadingError.online }
        return try NovelShelf.readFile(local)
    }
}

private final class BookDownloadLimit: NSObject, URLSessionDownloadDelegate {
    private let overLimit = OSAllocatedUnfairLock(initialState: false)
    var exceeded: Bool { overLimit.withLock { $0 } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > NovelText.limit {
            overLimit.withLock { $0 = true }
            downloadTask.cancel()
        }
    }
}
