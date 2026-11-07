import XCTest
import Combine
import OrielReading

@MainActor
final class NovelSessionTests: XCTestCase {
    func testOpeningBookSurvivesReaderViewFirstAppearance() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let library = NovelLibrary(root: folder, defaults: defaults)
        let book = try await library.shelf.add(data: Data("第一章\n打开目标书籍。".utf8), name: "目标.txt")
        let reader = NovelSession(library: library)
        reader.open(book)
        reader.start()
        try await settle(reader)
        XCTAssertEqual(reader.book?.id, book.id)
        XCTAssertEqual(reader.section, .reading)
    }

    func testTurningChapterPublishesSharedShelfProgressWithoutARefresh() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let library = NovelLibrary(root: folder, defaults: defaults)
        let book = try await library.shelf.add(data: Data("第一章\n出发。\n第二章\n到了。".utf8), name: "同步.txt")
        let reader = NovelSession(library: library)
        reader.open(book)
        try await settle(reader)
        var changes = 0
        let observation = library.objectWillChange.sink { changes += 1 }
        reader.turn(to: 1)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(library.places.place(for: book.id).chapter, 1)
        withExtendedLifetime(observation) {}
    }

    func testRemovingBookReturnsBothReadersToShelfAndClearsItsPlaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let library = NovelLibrary(root: folder, defaults: defaults)
        let first = NovelSession(library: library)
        let other = NovelSession(library: library)
        let book = try await library.shelf.add(data: Data("第一章 出发\n沿河而下。\n第二章 小船\n故人来信。".utf8), name: "沿河.txt")
        first.open(book)
        try await settle(first)
        first.turn(to: 1)
        first.markHere()
        other.open(book)
        try await settle(other)
        XCTAssertEqual(other.chapter, 1)
        XCTAssertEqual(library.places.marks(for: book.id).count, 1)

        other.remove(book)
        try await settle(other)
        XCTAssertNil(first.book)
        XCTAssertNil(other.book)
        XCTAssertEqual(first.section, .shelf)
        XCTAssertEqual(other.section, .shelf)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertNil(library.places.place(for: book.id).updated)
        XCTAssertTrue(library.places.marks(for: book.id).isEmpty)
    }

    func testClosingReaderDuringImportReleasesSessionWithoutOpeningBook() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "临时.txt")
        try "只存在于测试中。".write(to: file, atomically: true, encoding: .utf8)
        let library = NovelLibrary(root: folder.appending(path: "Books"))
        var active: NovelSession? = NovelSession(library: library)
        weak var closed = active
        active?.openFiles([file])
        active?.dispose()
        active = nil
        try await waitUntil { closed == nil }
        let books = try await library.shelf.books()
        XCTAssertTrue(books.isEmpty)
    }

    func testReturningToAnExistingReaderRestoresItsChapterAndOffsetForReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let library = NovelLibrary(root: folder, defaults: defaults)
        let chapters = (1...8).map { "第\($0)章\n河边的故事还没有结束。" }.joined(separator: "\n")
        let book = try await library.shelf.add(data: Data(chapters.utf8), name: "河岸.txt")
        let first = NovelSession(library: library)
        first.start()
        try await waitUntil { !library.books.isEmpty }
        first.open(book)
        try await settle(first)
        first.jump(to: 1, offset: 4)
        let other = NovelSession(library: library)
        other.open(book)
        try await settle(other)
        other.jump(to: 7, offset: 9)

        // The view calls start whenever its existing host reappears.
        first.start()
        first.dispose()
        other.dispose()
        let reopened = NovelSession(library: NovelLibrary(root: folder, defaults: defaults))
        reopened.open(book)
        try await settle(reopened)
        XCTAssertEqual(reopened.chapter, 1)
        XCTAssertEqual(reopened.offset, 4)
    }

    private func settle(_ session: NovelSession) async throws {
        try await waitUntil { session.busy == nil }
        XCTAssertNil(session.notice)
    }

    private func waitUntil(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done())
    }
}
