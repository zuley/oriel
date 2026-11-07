import XCTest

final class DataExportTests: XCTestCase {
    func testExportPublishesReadableSnapshotWithoutOverwritingEarlierExport() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let output = root.appending(path: "output")
        try FileManager.default.createDirectory(at: source.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("中文便签".utf8).write(to: source.appending(path: "Notes/one.json"))
        let exporter = DataExport(source: source)
        let first = try exporter.prepare(in: output, preferences: ["window.defaults.width": 420])
        try exporter.copyNotes(to: first)
        let published = try exporter.finish(first)
        XCTAssertEqual(try String(contentsOf: published.appending(path: "Notes/one.json"), encoding: .utf8), "中文便签")
        let second = try exporter.prepare(in: output, preferences: [:])
        let another = try exporter.finish(second)
        XCTAssertNotEqual(published, another)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.appending(path: "preferences.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }
    func testUnsafeDestinationAndSymbolicLinksFailWithoutPublishing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let output = root.appending(path: "output")
        try FileManager.default.createDirectory(at: source.appending(path: "Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let exporter = DataExport(source: source)
        XCTAssertThrowsError(try exporter.prepare(in: source.appending(path: "Notes"), preferences: [:]))
        try FileManager.default.createSymbolicLink(at: output.appending(path: "alias"), withDestinationURL: source)
        XCTAssertThrowsError(try exporter.prepare(in: output.appending(path: "alias"), preferences: [:]))
        try FileManager.default.createSymbolicLink(at: source.appending(path: "Notes/link"), withDestinationURL: output)
        let staging = try exporter.prepare(in: output, preferences: [:])
        XCTAssertThrowsError(try exporter.copyNotes(to: staging))
        try FileManager.default.removeItem(at: staging)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["alias"])
    }

    func testExportsOnlyApplicationPreferencesAndCleansInvalidPropertyList() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("book", forKey: "novel.place.v1.example")
        defaults.set("private", forKey: "unrelated.setting")
        let preferences = DataExport.preferences(defaults)
        XCTAssertEqual(preferences["novel.place.v1.example"] as? String, "book")
        XCTAssertNil(preferences["unrelated.setting"])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = DataExport(source: root.appending(path: "missing"))
        XCTAssertThrowsError(try exporter.prepare(in: root, preferences: ["bad": NSObject()]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

}
