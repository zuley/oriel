import XCTest

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaultsAndChangesSurviveReload() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppPreferences(defaults: store)
        XCTAssertEqual(settings.width, 280)
        XCTAssertEqual(settings.backgroundOpacity, 0.75)
        XCTAssertTrue(settings.openAtLaunch)
        settings.width = 420
        settings.contentOpacity = 0.25
        settings.openAtLaunch = false
        let restored = AppPreferences(defaults: store)
        XCTAssertEqual(restored.width, 420)
        XCTAssertEqual(restored.contentOpacity, 0.25)
        XCTAssertFalse(restored.openAtLaunch)
    }
    func testInvalidValuesAreClampedAndResetRestoresOnlyOwnedDefaults() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(-500, forKey: "window.defaults.width")
        store.set("preserved", forKey: "novel.example")
        let settings = AppPreferences(defaults: store)
        XCTAssertEqual(settings.width, 120)
        settings.width = 2000
        settings.height = 1
        settings.backgroundOpacity = -.infinity
        settings.contentOpacity = 5
        XCTAssertEqual(settings.width, 900)
        XCTAssertEqual(settings.height, 90)
        XCTAssertEqual(settings.backgroundOpacity, 0.75)
        XCTAssertEqual(settings.contentOpacity, 1)
        let reloaded = AppPreferences(defaults: store)
        XCTAssertEqual(reloaded.width, 900)
        XCTAssertEqual(reloaded.height, 90)
        XCTAssertEqual(reloaded.backgroundOpacity, 0.75)
        XCTAssertEqual(reloaded.contentOpacity, 1)
        settings.reset()
        XCTAssertEqual(settings.width, 280)
        XCTAssertEqual(settings.height, 360)
        XCTAssertEqual(settings.contentOpacity, 0.75)
        XCTAssertEqual(store.string(forKey: "novel.example"), "preserved")
    }

}
