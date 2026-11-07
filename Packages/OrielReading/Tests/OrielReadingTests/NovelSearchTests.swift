import XCTest
import OrielReading

final class NovelSearchTests: XCTestCase {
    func testSimplifiedSearchJumpsToOriginalUTF16OffsetAfterEmoji() async throws {
        let chapters = try NovelText.chapters(data: Data("第一章\n🍃春風裡有一片葉。\n第二章\n春风又来了。".utf8))
        let result = try await NovelSearch.find(" 春风 ", in: chapters)
        XCTAssertEqual(result.hits.map(\.chapter), [0, 1])
        XCTAssertEqual(result.hits.map(\.offset), [2, 0])
        XCTAssertTrue(result.hits[0].excerpt.contains("春風"))
        let limited = try await NovelSearch.find("春", in: chapters, limit: 1)
        XCTAssertEqual(limited.hits.count, 1)
        XCTAssertTrue(limited.hasMore)
    }
}

extension NovelSearchTests {
    func testChapterAndShelfFilterMatchesBothScriptsAndFullWidthLetters() {
        XCTAssertTrue(NovelQuery(" 宝玉 ").matches("寶玉初试云雨情"))
        XCTAssertTrue(NovelQuery("阿q").matches("阿Ｑ正傳"))
        XCTAssertTrue(NovelQuery("  ").matches("目录"))
        XCTAssertFalse(NovelQuery("孔乙己").matches("阿Q正传"))
    }
}
