import XCTest
import OrielReading

@MainActor
final class NovelShelfTests: XCTestCase {
    func testPreviouslyDownloadedBookRemainsReadableFromLocalShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "pg-42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = #"{"id":"pg-42","title":"旧版本藏书","author":null,"chapterCount":1,"sourceID":42,"added":0}"#
        try Data(metadata.utf8).write(to: folder.appending(path: "book.json"))
        let chapters = try NovelText.chapters(data: Data("第一章\n本地副本仍可阅读。".utf8))
        try JSONEncoder().encode(chapters).write(to: folder.appending(path: "chapters.json"))

        let shelf = NovelShelf(root: root)
        let books = try await shelf.books()
        let saved = try XCTUnwrap(books.first)
        XCTAssertEqual(saved.sourceID, 42)
        let reopened = try await shelf.chapters(of: saved)
        XCTAssertEqual(reopened.first?.text, "本地副本仍可阅读。")
    }

    func testDamagedLegacyBookIsRepairedInPlaceFromMatchingLocalOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "pg-42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = #"{"id":"pg-42","title":"旧版本藏书","author":"原作者","chapterCount":2,"sourceID":42,"added":0}"#
        try Data(metadata.utf8).write(to: folder.appending(path: "book.json"))
        try Data().write(to: folder.appending(path: "chapters.json"))
        let original = root.appending(path: "原书.txt")
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
        let shelf = NovelShelf(root: root)
        let existing = try await shelf.books()
        let saved = try XCTUnwrap(existing.first)
        let repaired = try await shelf.replace(file: original, of: saved)
        XCTAssertEqual(repaired.id, saved.id)
        XCTAssertEqual(repaired.title, saved.title)
        XCTAssertEqual(repaired.author, saved.author)
        XCTAssertEqual(repaired.sourceID, saved.sourceID)
        let books = try await shelf.books()
        XCTAssertEqual(books.count, 1)
        let chapters = try await shelf.chapters(of: repaired)
        XCTAssertEqual(chapters.map(\.text), ["第一段。", "第二段。"])
    }

    func testLegacyRepairRejectsAnotherEditionWithoutChangingDamagedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "pg-42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = #"{"id":"pg-42","title":"旧版本藏书","author":null,"chapterCount":1,"sourceID":42,"added":0}"#
        try Data(metadata.utf8).write(to: folder.appending(path: "book.json"))
        try Data().write(to: folder.appending(path: "chapters.json"))
        let wrong = root.appending(path: "另一版.txt")
        try Data("[eBook #43]\n第一章\n其他内容。".utf8).write(to: wrong)
        let shelf = NovelShelf(root: root)
        let existing = try await shelf.books()
        let saved = try XCTUnwrap(existing.first)
        do { _ = try await shelf.replace(file: wrong, of: saved); XCTFail("Wrong edition replaced the old book") }
        catch ReadingError.wrongEdition {}
        let books = try await shelf.books()
        XCTAssertEqual(books, [saved])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "chapters.json")), Data())
    }

    func testDamagedLocalBookIsRepairedInPlaceFromTheSameFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Data("第一章 出发\n第一段。\n第二章 抵达\n第二段。".utf8)
        let shelf = NovelShelf(root: root)
        _ = try await shelf.add(data: text, name: "本地书.txt")
        let existing = try await shelf.books()
        let saved = try XCTUnwrap(existing.first)
        try Data().write(to: root.appending(path: saved.id).appending(path: "chapters.json"))
        // The same bytes under another name still identify the same book.
        let original = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: original) }
        try text.write(to: original)

        let repaired = try await shelf.replace(file: original, of: saved)
        XCTAssertEqual(repaired.id, saved.id)
        XCTAssertEqual(repaired.title, saved.title)
        XCTAssertEqual(repaired.chapterCount, 2)
        XCTAssertEqual(repaired.added, saved.added)
        let books = try await shelf.books()
        XCTAssertEqual(books, [repaired])
        let chapters = try await shelf.chapters(of: repaired)
        XCTAssertEqual(chapters.map(\.text), ["第一段。", "第二段。"])
    }

    func testLocalRepairRejectsAnotherFileWithoutChangingDamagedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = NovelShelf(root: root)
        _ = try await shelf.add(data: Data("第一章\n原文。".utf8), name: "本地书.txt")
        let existing = try await shelf.books()
        let saved = try XCTUnwrap(existing.first)
        let chapters = root.appending(path: saved.id).appending(path: "chapters.json")
        try Data().write(to: chapters)
        let other = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("第一章\n别的内容。".utf8).write(to: other)

        do { _ = try await shelf.replace(file: other, of: saved); XCTFail("Another file replaced the damaged book") }
        catch ReadingError.wrongEdition {}
        let books = try await shelf.books()
        XCTAssertEqual(books, [saved])
        XCTAssertEqual(try Data(contentsOf: chapters), Data())
    }

    func testRepairRebuildsMetadataThatItselfWentMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = Data("第一章\n原文。".utf8)
        let shelf = NovelShelf(root: root)
        _ = try await shelf.add(data: text, name: "本地书.txt")
        let existing = try await shelf.books()
        let saved = try XCTUnwrap(existing.first)
        let folder = root.appending(path: saved.id)
        try FileManager.default.removeItem(at: folder.appending(path: "book.json"))
        try Data().write(to: folder.appending(path: "chapters.json"))
        let original = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: original) }
        try text.write(to: original)

        let repaired = try await shelf.replace(file: original, of: saved)
        XCTAssertEqual(repaired.title, saved.title)
        XCTAssertEqual(repaired.added, saved.added)
        let books = try await shelf.books()
        XCTAssertEqual(books.map(\.id), [saved.id])
        XCTAssertEqual(books.map(\.title), [saved.title])
    }

    func testReopenWithoutOriginalDeduplicatesAndRemovesOnlyLibraryCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = NovelShelf(root: root)
        let text = Data("第一章\n雨停了。".utf8)
        let first = try await shelf.add(data: text, name: "春天.txt")
        let duplicate = try await shelf.add(data: text, name: "副本.txt")
        XCTAssertEqual(duplicate.id, first.id)
        let reopened = NovelShelf(root: root)
        let books = try await reopened.books()
        XCTAssertEqual(books.map(\.title), ["春天"])
        let chapters = try await reopened.chapters(of: first)
        XCTAssertEqual(chapters.first?.text, "雨停了。")
        try await reopened.remove(first)
        let afterRemoval = try await shelf.books()
        XCTAssertTrue(afterRemoval.isEmpty)
    }
}

extension NovelShelfTests {
    func testBatchImportKeepsHealthyBooksAndIdentifiesFilesThatCanBeRetried() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appending(path: "春.txt"), duplicate = dir.appending(path: "副本.txt")
        let bad = dir.appending(path: "空白.txt"), second = dir.appending(path: "夏.txt")
        try Data("花开了。".utf8).write(to: first)
        try FileManager.default.copyItem(at: first, to: duplicate)
        try Data().write(to: bad)
        try Data("下雨了。".utf8).write(to: second)
        let shelf = NovelShelf(root: dir.appending(path: "library"))
        let result = try await shelf.add(files: [first, duplicate, bad, second])
        XCTAssertEqual(result.books.map(\.title), ["春", "夏"])
        XCTAssertEqual(result.failures.map(\.file), [bad])
        try FileManager.default.removeItem(at: first)
        let fresh = NovelShelf(root: dir.appending(path: "library"))
        let chapters = try await fresh.chapters(of: result.books[0])
        XCTAssertEqual(chapters.first?.text, "花开了。")
        let saved = try await fresh.books()
        XCTAssertEqual(saved.count, 2)
    }
}

extension NovelShelfTests {
    func testLargeOrBrokenFileDoesNotCreatePartialEntry() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = NovelShelf(root: dir.appending(path: "books"))
        let large = dir.appending(path: "长篇.txt")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 32 * 1024 * 1024 + 1)
        try handle.close()
        do { _ = try await shelf.add(file: large); XCTFail("Oversize file admitted") } catch ReadingError.oversized {}
        do { _ = try await shelf.add(data: Data("不完整的书".utf8), name: "破损.epub"); XCTFail("Invalid EPUB admitted") }
        catch ReadingError.damaged {}
        let books = try await shelf.books()
        XCTAssertTrue(books.isEmpty)
    }
}

extension NovelShelfTests {
    func testReimportRepairsAnIncompleteCachedBookWithoutChangingItsIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = NovelShelf(root: root)
        let data = Data("第一章 河岸\n书还在。".utf8)
        let first = try await shelf.add(data: data, name: "河岸.txt")
        try Data().write(to: root.appending(path: first.id).appending(path: "chapters.json"))
        let repaired = try await shelf.add(data: data, name: "又一个副本.txt")
        XCTAssertEqual(first, repaired)
        let chapters = try await shelf.chapters(of: repaired)
        XCTAssertEqual(chapters.first?.text, "书还在。")
    }
}

extension NovelShelfTests {
    func testExportedShelfReopensIndependentlyAndLeavesSourceIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = NovelShelf(root: root.appending(path: "source"))
        let book = try await shelf.add(data: Data("第一章\n独立的阅读副本。".utf8), name: "导出测试.txt")
        let destination = root.appending(path: "export")
        try await shelf.exportSnapshot(to: destination)
        let copy = NovelShelf(root: destination)
        let copiedBooks = try await copy.books()
        XCTAssertEqual(copiedBooks, [book])
        let chapters = try await copy.chapters(of: book)
        XCTAssertEqual(chapters.first?.text, "独立的阅读副本。")
        try await copy.remove(book)
        let originals = try await shelf.books()
        XCTAssertEqual(originals, [book])
    }
}
