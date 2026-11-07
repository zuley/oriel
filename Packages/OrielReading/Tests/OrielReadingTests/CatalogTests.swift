import XCTest
import OrielReading

@MainActor
final class CatalogTests: XCTestCase {
    func testBadMirrorFallsBackThenAnOfflineReopenMakesNoRequest() async throws {
        actor Requests {
            var urls: [URL] = []
            func fetch(_ url: URL) throws -> Data {
                urls.append(url)
                switch urls.count {
                case 1: return Data("not a book".utf8)
                case 2: return Data("[eBook #24264]\n*** START OF THE PROJECT GUTENBERG EBOOK 紅樓夢 ***\n第一回\n一阵清风。\n*** END OF THE PROJECT GUTENBERG EBOOK 紅樓夢 ***".utf8)
                default: throw URLError(.notConnectedToInternet)
                }
            }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogNovel.all[0]
        let requests = Requests()
        let library = NovelShelf(root: root)
        let loader = NovelCatalogLoader(shelf: library, fetch: { try await requests.fetch($0) })
        let book = try await loader.open(source)
        let again = try await loader.open(source)
        let urls = await requests.urls
        XCTAssertEqual(urls, source.mirrors)
        XCTAssertEqual(book, again)
        XCTAssertEqual(book.sourceID, source.id)
    }
}

extension CatalogTests {
    func testOnlineSearchAcceptsOnlyBookEntriesAndReusesCuratedNames() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
         <entry><id>https://www.gutenberg.org/ebooks/authors/search.opds/</id><title>Authors</title></entry>
         <entry><id>https://www.gutenberg.org/ebooks/27166.opds</id><title>吶喊 (Chinese)</title><content>Xun Lu</content></entry>
         <entry><id>https://www.gutenberg.org/ebooks/24264.opds</id><title>紅樓夢 (Chinese)</title><content>Xueqin Cao</content></entry>
         <entry><id>https://other.example/ebooks/200.opds</id><title>Other (Chinese)</title></entry>
         <link rel="next" href="/ebooks/search.opds/?query=l.zh&amp;start_index=26"/>
        </feed>
        """
        let page = try CatalogSearch.parse(Data(xml.utf8))
        XCTAssertEqual(page.books.map(\.id), [27166, 24264])
        XCTAssertEqual(page.books.last?.author, "曹雪芹")
        XCTAssertEqual(page.books.first?.originalTitle, "吶喊")
        XCTAssertEqual(page.next, 26)
    }
}

extension CatalogTests {
    func testCancellingAnInFlightRequestDoesNotTryAnotherMirrorOrCreateBook() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, handle) = AsyncStream<URL>.makeStream()
        let shelf = NovelShelf(root: root)
        let loader = NovelCatalogLoader(shelf: shelf) { url in
            handle.yield(url)
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        let task = Task { try await loader.open(CatalogNovel.all[0]) }
        var iterator = started.makeAsyncIterator()
        let firstURL = await iterator.next()
        XCTAssertEqual(firstURL, CatalogNovel.all[0].mirrors[0])
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read succeeded") } catch is CancellationError {}
        handle.finish()
        let otherURL = await iterator.next()
        XCTAssertNil(otherURL)
        let books = try await shelf.books()
        XCTAssertTrue(books.isEmpty)
    }

    func testBothMirrorsUnavailableLeavesShelfReadyForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = NovelShelf(root: root)
        let loader = NovelCatalogLoader(shelf: shelf) { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await loader.open(CatalogNovel.all[1]); XCTFail("Offline fetch succeeded") }
        catch ReadingError.online {}
        let books = try await shelf.books()
        XCTAssertTrue(books.isEmpty)
    }
}

extension CatalogTests {
    func testWrongEditionWithTheSameTitleIsRejectedAndExplained() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = CatalogNovel.all[0]
        let wrong = Data("Title: 紅樓夢\n[eBook #42]\n*** START OF THE PROJECT GUTENBERG EBOOK 紅樓夢 ***\n第一回\n不同版本。\n*** END OF THE PROJECT GUTENBERG EBOOK 紅樓夢 ***".utf8)
        let shelf = NovelShelf(root: root)
        let loader = NovelCatalogLoader(shelf: shelf) { _ in wrong }
        do { _ = try await loader.open(source); XCTFail("Mismatched edition admitted") }
        catch ReadingError.damaged {}
        let books = try await shelf.books()
        XCTAssertTrue(books.isEmpty)
    }
}
