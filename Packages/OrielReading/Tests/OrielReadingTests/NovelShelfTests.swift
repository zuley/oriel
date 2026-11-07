import XCTest
import OrielReading

@MainActor
final class NovelShelfTests: XCTestCase {
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
