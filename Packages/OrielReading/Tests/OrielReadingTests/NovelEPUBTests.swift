import XCTest
import ZIPFoundation
import OrielReading

final class NovelEPUBTests: XCTestCase {
    func testSpineOrderMetadataAndReadableText() throws {
        let archive = try Archive(accessMode: .create)
        let parts = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='Book/novel.opf'/></rootfiles></container>",
            "Book/novel.opf": """
            <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>雨巷</dc:title><dc:creator>小林</dc:creator></metadata>
            <manifest><item id="a" href="一.xhtml" media-type="application/xhtml+xml"/><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="b"/><itemref idref="a"/></spine></package>
            """,
            "Book/b.xhtml": "<html><head><title>章</title></head><body><h2>出发</h2><p>窗外<em>晴</em>了。</p><p>第二段。</p><script>不可见</script></body></html>",
            "Book/一.xhtml": "<html><body><h1>抵达</h1><p>到了。</p></body></html>"
        ]
        for (path, source) in parts {
            let data = Data(source.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
        let book = try NovelEPUB.read(XCTUnwrap(archive.data))
        XCTAssertEqual(book.title, "雨巷")
        XCTAssertEqual(book.author, "小林")
        XCTAssertEqual(book.chapters.map(\.title), ["出发", "抵达"])
        XCTAssertEqual(book.chapters.first?.text, "窗外晴了。\n\n第二段。")
    }
}

extension NovelEPUBTests {
    func testEPUBNavigationSplitsSharedSpineFileAndPreservesPreformattedLines() throws {
        let archive = try Archive(accessMode: .create)
        let parts = [
            "META-INF/container.xml": "<container><rootfile full-path='book.opf'/></container>",
            "book.opf": """
            <package><metadata/><manifest><item id="nav" href="nav/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="book" href="text/all.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="nav"/><itemref idref="book"/></spine></package>
            """,
            "nav/toc.xhtml": """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>
            <li><a href="../text/all.xhtml#first">启程</a></li><li><a href="../text/all.xhtml#next">回家</a></li></ol></nav></body></html>
            """,
            "text/all.xhtml": "<html><body><section id='first'><p>第一段。</p></section><section id='next'><pre>河岸\n灯光</pre></section></body></html>"
        ]
        for (path, source) in parts {
            let data = Data(source.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { start, size in
                data.subdata(in: Int(start)..<(Int(start) + size))
            }
        }
        let book = try NovelEPUB.read(XCTUnwrap(archive.data))
        XCTAssertEqual(book.chapters.map(\.title), ["启程", "回家"])
        XCTAssertEqual(book.chapters.map(\.text), ["第一段。", "河岸\n灯光"])
    }
}

extension NovelEPUBTests {
    func testUnresolvedRequiredChapterRejectsImportWithoutCreatingPartialBook() async throws {
        let invalidReferences = [
            ("<itemref idref='missing'/>", ""),
            ("<itemref/>", ""),
            ("<itemref idref='b'/>", "<item id='b' href='https://example.invalid/b.xhtml' media-type='application/xhtml+xml'/>"),
            ("<itemref idref='b'/>", "<item id='b' href='absent.xhtml' media-type='application/xhtml+xml'/>")
        ]
        for (reference, manifest) in invalidReferences {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let shelf = NovelShelf(root: root)
            let data = try chapterArchive(extraSpine: reference, extraManifest: manifest)
            do {
                _ = try await shelf.add(data: data, name: "缺章.epub")
                XCTFail("Required chapter must reject the entire import: \(reference)")
            } catch ReadingError.damaged {
                // The caller can explain that the original EPUB needs repair.
            }
            let saved = try await shelf.books()
            XCTAssertTrue(saved.isEmpty)
        }
    }

    func testExplicitlyNonlinearItemCanBeSkipped() throws {
        let data = try chapterArchive(extraSpine: "<itemref idref='supplement' linear='no'/>")
        let book = try NovelEPUB.read(data)
        XCTAssertEqual(book.chapters.map(\.title), ["第一章"])
        XCTAssertEqual(book.chapters.map(\.text), ["完整正文。"])
    }

    private func chapterArchive(extraSpine: String, extraManifest: String = "") throws -> Data {
        let archive = try Archive(accessMode: .create)
        let parts = [
            "META-INF/container.xml": "<container><rootfile full-path='book.opf'/></container>",
            "book.opf": """
            <package><metadata/><manifest>
            <item id='a' href='a.xhtml' media-type='application/xhtml+xml'/>\(extraManifest)
            </manifest><spine><itemref idref='a'/>\(extraSpine)</spine></package>
            """,
            "a.xhtml": "<html><body><h1>第一章</h1><p>完整正文。</p></body></html>"
        ]
        for (path, source) in parts {
            let data = Data(source.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
        return try XCTUnwrap(archive.data)
    }
}
