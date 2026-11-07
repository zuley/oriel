import XCTest
import OrielReading

final class NovelTextTests: XCTestCase {
    func testLocalTextPreservesPreludeParagraphsAndRecognizesChineseChapters() throws {
        let input = "写在前面\r\n\r\n第一章 初见\r\n他说。\r\n她答。\r\n第二章\r\n又一天。"
        let chapters = try NovelText.chapters(data: Data(input.utf8))
        XCTAssertEqual(chapters.map(\.title), ["序言", "第一章 初见", "第二章"])
        XCTAssertEqual(chapters.map(\.text), ["写在前面", "他说。\n她答。", "又一天。"])
    }

    func testVolumeAndPlainTableOfContentsDoNotOpenOnEmptyChapters() throws {
        let input = """
        目录
        第一卷 少年
        第一章 出发
        第二章 同行
        第二卷 归来
        第一章 重逢

        第一卷 少年
        第一章 出发
        船离了岸。
        第二章 同行
        她撑起伞。
        第二卷 归来
        第一章 重逢
        故人还在。
        """
        let chapters = try NovelText.chapters(data: Data(input.utf8))
        XCTAssertEqual(chapters.map(\.title), ["第一卷 少年 · 第一章 出发", "第一卷 少年 · 第二章 同行", "第二卷 归来 · 第一章 重逢"])
        XCTAssertEqual(chapters.map(\.text), ["船离了岸。", "她撑起伞。", "故人还在。"])
    }

    func testCatalogPrintWrapsAndRepeatedRunningHeadingStayInOneChapter() throws {
        let input = """
        *** START OF THE PROJECT GUTENBERG EBOOK 範例 ***
        Produced by example
        第九十九回：夜雨
        第四回中已經說過。
        天又亮了。
        第一○○回：重逢
        --------
        第一○○回：重逢
        一切如常。
        *** END OF THE PROJECT GUTENBERG EBOOK 範例 ***
        """
        let chapters = try NovelText.chapters(data: Data(input.utf8), gutenberg: true)
        XCTAssertEqual(chapters.map(\.title), ["第九十九回：夜雨", "第一○○回：重逢"])
        XCTAssertEqual(chapters.first?.text, "第四回中已經說過。天又亮了。")
    }
}

extension NovelTextTests {
    func testLongNamedChapterKeepsOneEntryAndGutenbergPreservesActualPreface() throws {
        let prose = String(repeating: "山路有尽头，故事还很长。", count: 1800)
        let data = Data(("*** START OF THE PROJECT GUTENBERG EBOOK 山路 ***\n序言里有一则独立的故事，读它才能知道两个人为什么出发。\n第一回 出发\n" + prose +
            "\n*** END OF THE PROJECT GUTENBERG EBOOK 山路 ***").utf8)
        let result = try NovelText.chapters(data: data, gutenberg: true)
        XCTAssertEqual(result.map(\.title), ["序言", "第一回 出发"])
        XCTAssertEqual(result.last?.text.count, prose.count)
    }
}

extension NovelTextTests {
    func testSimplifiedReadingPreservesOriginalSearchAndBookmarkOffsets() throws {
        let chapter = try XCTUnwrap(NovelText.chapters(data: Data("第一章 樹葉\n上文。\n🍃風吹過綠葉。".utf8)).first)
        let rendered = chapter.simplified()
        XCTAssertEqual(rendered.title, "第一章 树叶")
        XCTAssertEqual(rendered.text, "上文。\n🍃风吹过绿叶。")
        XCTAssertEqual((chapter.text as NSString).range(of: "綠葉"), (rendered.text as NSString).range(of: "绿叶"))
    }
}

extension NovelTextTests {
    func testCommonLocalEncodingsAndUnreadableFiles() throws {
        let content = "第一章\n春雨。"
        let values = [
            Data([0xef, 0xbb, 0xbf]) + Data(content.utf8),
            Data([0xff, 0xfe]) + (try XCTUnwrap(content.data(using: .utf16LittleEndian))),
            Data([0xfe, 0xff]) + (try XCTUnwrap(content.data(using: .utf16BigEndian)))
        ]
        for data in values {
            XCTAssertEqual(try NovelText.chapters(data: data).first?.text, "春雨。")
        }
        XCTAssertEqual(try NovelText.chapters(data: Data([0xd6,0xd0,0xce,0xc4])).first?.text, "中文")
        for invalid in [Data(), Data("  \n\t".utf8), Data([0,1,2,3]), Data([1,2,3,4])] {
            XCTAssertThrowsError(try NovelText.chapters(data: invalid))
        }
    }
}
