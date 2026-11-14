import XCTest
import Combine
import OrielReading

@MainActor
final class NovelSessionTests: XCTestCase {
    func testEmptyLibraryStartsOnLocalShelf() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = NovelLibrary(root: folder)
        let reader = NovelSession(library: library)
        var refreshes = 0
        let observation = library.$books.dropFirst().sink { _ in refreshes += 1 }
        reader.start()
        try await waitUntil { refreshes > 0 }
        XCTAssertEqual(reader.section, .shelf)
        withExtendedLifetime(observation) {}
    }

    func testImportingLocalFileFromEmptyShelfOpensReader() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "本地书.txt")
        try "第一章\n只从本机导入。".write(to: file, atomically: true, encoding: .utf8)
        let library = NovelLibrary(root: folder.appending(path: "Books"))
        let reader = NovelSession(library: library)
        reader.start()
        reader.openFiles([file])
        try await settle(reader)
        XCTAssertEqual(reader.section, .reading)
        XCTAssertEqual(reader.book?.title, "本地书")
        XCTAssertEqual(library.books.count, 1)
    }

    func testRetryingDamagedLegacyBookKeepsItsIdentityAndReadingPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let books = folder.appending(path: "Books")
        let legacy = books.appending(path: "pg-42")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let metadata = #"{"id":"pg-42","title":"旧版本藏书","author":null,"chapterCount":2,"sourceID":42,"added":0}"#
        try Data(metadata.utf8).write(to: legacy.appending(path: "book.json"))
        try Data().write(to: legacy.appending(path: "chapters.json"))
        let original = folder.appending(path: "同版.txt")
        let text = """
        The Project Gutenberg eBook [eBook #42]
        *** START OF THE PROJECT GUTENBERG EBOOK 示例 ***
        第一章 出发
        第一段。
        第二章 抵达
        第二段。
        *** END OF THE PROJECT GUTENBERG EBOOK 示例 ***
        """
        try Data(text.utf8).write(to: original)
        let library = NovelLibrary(root: books, defaults: defaults)
        library.places.save(book: "pg-42", chapter: 1, offset: 2)
        let reader = NovelSession(library: library)
        let existing = try await library.shelf.books()
        let saved = try XCTUnwrap(existing.first)
        reader.open(saved)
        try await waitUntil { reader.busy == nil && reader.notice != nil }
        XCTAssertEqual(reader.retryTitle, "重新导入")
        reader.retry { target in reader.openFiles([original], replacing: target) }
        try await settle(reader)
        XCTAssertEqual(reader.section, .reading)
        XCTAssertEqual(reader.book?.id, saved.id)
        XCTAssertEqual(reader.chapter, 1)
        XCTAssertEqual(reader.offset, 2)
        XCTAssertEqual(library.books.map(\.id), [saved.id])
    }

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
        XCTAssertEqual(library.place(for: book.id).chapter, 1)
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
        XCTAssertNil(library.place(for: book.id).updated)
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

    // R03: scrolling no longer writes UserDefaults on every position change.
    private func storedOffset(_ defaults: UserDefaults, _ book: String) -> Int? {
        defaults.dictionary(forKey: "novel.place.v1." + book)?["offset"] as? Int
    }

    func testScrollingWithinAChapterWritesThePlaceOnceAfterAPause() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let library = NovelLibrary(root: folder, defaults: defaults, placeDelay: .milliseconds(200))
        let book = try await library.shelf.add(data: Data(("第一章\n" + String(repeating: "长段落。", count: 400)).utf8), name: "滚动.txt")
        let reader = NovelSession(library: library)
        reader.open(book)
        try await settle(reader)
        XCTAssertEqual(storedOffset(defaults, book.id), 0)

        for position in 1...100 { reader.saveOffset(position * 3, bookID: book.id, index: 0) }
        XCTAssertEqual(storedOffset(defaults, book.id), 0, "Scrolling must not write on every step.")
        XCTAssertEqual(library.place(for: book.id).offset, 300, "Readers still see the latest place.")
        try await waitUntil { self.storedOffset(defaults, book.id) == 300 }
    }

    func testChapterChangesAndClosingWriteThePlaceImmediately() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let library = NovelLibrary(root: folder, defaults: defaults, placeDelay: .seconds(60))
        let book = try await library.shelf.add(data: Data("第一章\n出发了很久很久。\n第二章\n到了。".utf8), name: "换章.txt")
        let reader = NovelSession(library: library)
        reader.open(book)
        try await settle(reader)

        reader.saveOffset(4, bookID: book.id, index: 0)
        reader.turn(to: 1)
        XCTAssertEqual(defaults.dictionary(forKey: "novel.place.v1." + book.id)?["chapter"] as? Int, 1)

        reader.saveOffset(2, bookID: book.id, index: 1)
        reader.showShelf()
        XCTAssertEqual(storedOffset(defaults, book.id), 2)

        reader.open(book)
        try await settle(reader)
        reader.saveOffset(1, bookID: book.id, index: 1)
        reader.dispose()
        XCTAssertEqual(storedOffset(defaults, book.id), 1)

        let other = NovelSession(library: library)
        other.open(book)
        try await settle(other)
        other.saveOffset(3, bookID: book.id, index: 1)
        library.flushPlaces()
        XCTAssertEqual(storedOffset(defaults, book.id), 3)
    }

    // R21: tabs reading the same book share one decoded copy.
    func testTwoReadersOfOneBookShareTheDecodedChapters() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let library = NovelLibrary(root: folder, defaults: defaults)
        let book = try await library.shelf.add(data: Data("第一章\n共享。\n第二章\n同一份。".utf8), name: "共享.txt")
        let first = NovelSession(library: library)
        let second = NovelSession(library: library)
        first.open(book)
        try await settle(first)
        second.open(book)
        try await settle(second)
        func storage(_ session: NovelSession) -> UnsafeRawPointer? {
            session.chapters.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        }
        XCTAssertEqual(second.chapters, first.chapters)
        XCTAssertEqual(storage(second), storage(first), "The second tab must not decode its own copy.")
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
