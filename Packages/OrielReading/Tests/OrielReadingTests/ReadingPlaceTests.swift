import XCTest
import OrielReading

@MainActor
final class ReadingPlaceTests: XCTestCase {
    func testPlaceSurvivesNewInstanceAndIsScopedToBook() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = ReadingPlaces(defaults: defaults)
        places.save(book: "first", chapter: 2, offset: 127)
        let restarted = ReadingPlaces(defaults: defaults)
        XCTAssertEqual(restarted.place(for: "first").chapter, 2)
        XCTAssertEqual(restarted.place(for: "first").offset, 127)
        XCTAssertEqual(restarted.place(for: "second").offset, 0)
        restarted.remove(book: "first")
        XCTAssertEqual(places.place(for: "first").chapter, 0)
    }
}

extension ReadingPlaceTests {
    func testBookmarksKeepExactPositionAndAreRemovedWithTheirBook() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = ReadingPlaces(defaults: defaults)
        places.addMark(book: "first", chapter: 1, offset: 32, excerpt: "窗外")
        places.addMark(book: "first", chapter: 1, offset: 32, excerpt: "窗外")
        places.addMark(book: "other", chapter: 0, offset: 0, excerpt: "开头")
        let again = ReadingPlaces(defaults: defaults)
        XCTAssertEqual(again.marks(for: "first").map(\.offset), [32])
        again.remove(book: "first")
        XCTAssertTrue(places.marks(for: "first").isEmpty)
        XCTAssertEqual(places.marks(for: "other").first?.excerpt, "开头")
    }
}
