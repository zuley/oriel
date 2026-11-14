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

    func testFactoryDefaultsMatchThePortraitPreset() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppPreferences(defaults: store)
        XCTAssertEqual(settings.currentPreset?.id, "portrait")
    }

    func testEveryPresetStaysWithinSupportedBounds() {
        XCTAssertGreaterThanOrEqual(WindowPreset.all.count, 3)
        for preset in WindowPreset.all {
            XCTAssertTrue((120...900).contains(preset.width), "\(preset.title) 宽度越界")
            XCTAssertTrue((90...1200).contains(preset.height), "\(preset.title) 高度越界")
            XCTAssertTrue((0...1).contains(preset.backgroundOpacity), "\(preset.title) 背景透明度越界")
            XCTAssertTrue((0...1).contains(preset.contentOpacity), "\(preset.title) 内容透明度越界")
        }
    }

    func testPresetsOfferTallWideAndSquareShapes() throws {
        XCTAssertEqual(WindowPreset.all.count, 3)
        let portrait = try XCTUnwrap(WindowPreset.all.first { $0.id == "portrait" })
        let landscape = try XCTUnwrap(WindowPreset.all.first { $0.id == "landscape" })
        let square = try XCTUnwrap(WindowPreset.all.first { $0.id == "square" })
        XCTAssertTrue(portrait.height > portrait.width, "竖版应高于宽")
        XCTAssertTrue(landscape.width > landscape.height, "横版应宽于高")
        XCTAssertEqual(square.width, square.height, "正方形应等边")
    }

    func testApplyingEveryPresetWritesAllFourValuesAndSurvivesReload() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppPreferences(defaults: store)
        for preset in WindowPreset.all {
            settings.apply(preset)
            XCTAssertEqual(settings.width, preset.width)
            XCTAssertEqual(settings.height, preset.height)
            XCTAssertEqual(settings.backgroundOpacity, preset.backgroundOpacity)
            XCTAssertEqual(settings.contentOpacity, preset.contentOpacity)
            XCTAssertEqual(settings.currentPreset?.id, preset.id)
        }
        let restored = AppPreferences(defaults: store)
        XCTAssertEqual(restored.currentPreset?.id, WindowPreset.all.last?.id)
    }

    func testCustomValuesHaveNoPresetAndResetReturnsToPortrait() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppPreferences(defaults: store)
        settings.width = 420
        XCTAssertNil(settings.currentPreset, "A hand-edited size is not a preset.")
        settings.apply(WindowPreset.all[0])
        XCTAssertEqual(settings.currentPreset?.id, WindowPreset.all[0].id)
        settings.width = 500
        settings.reset()
        XCTAssertEqual(settings.currentPreset?.id, "portrait")
        XCTAssertEqual(settings.width, 280)
        XCTAssertEqual(settings.height, 360)
        XCTAssertEqual(settings.backgroundOpacity, 0.75)
        XCTAssertEqual(settings.contentOpacity, 0.75)
    }

    func testPresetMatchingToleratesSliderRounding() throws {
        let suite = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppPreferences(defaults: store)
        settings.backgroundOpacity = 0.7500005
        XCTAssertEqual(settings.currentPreset?.id, "portrait")
        settings.backgroundOpacity = 0.8
        XCTAssertNil(settings.currentPreset)
    }
}
