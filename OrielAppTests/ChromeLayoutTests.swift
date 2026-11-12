import XCTest

final class ChromeLayoutTests: XCTestCase {
    func testSingleTabKeepsTheToolbarOnlyAndContentStartsBelowIt() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1)
        XCTAssertEqual(layout.tabMode, .none)
        XCTAssertEqual(layout.contentTop, 32)
        XCTAssertEqual(layout.tabStrip.height, 0)
        XCTAssertTrue(layout.addTab.isEmpty)
    }

    func testFirstContentTabOpensTheStripWithoutAToolbarAddButton() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1,
                                       showsSingleTab: true)
        XCTAssertEqual(layout.tabMode, .strip)
        XCTAssertEqual(layout.contentTop, 54)
        XCTAssertTrue(layout.addTab.isEmpty)
    }

    func testSeveralTabsInATallWindowUseAStrip() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 3)
        XCTAssertEqual(layout.tabMode, .strip)
        XCTAssertEqual(layout.tabStrip, CGRect(x: 6, y: 28, width: 268, height: 22))
        XCTAssertEqual(layout.contentTop, 54)
    }

    func testShortWindowsMoveTabsIntoTheToolbarTitle() {
        let layout = ChromeLayout.make(width: 240, height: 150, tabCount: 2)
        XCTAssertEqual(layout.tabMode, .switcher)
        XCTAssertEqual(layout.contentTop, 32)
        XCTAssertNotNil(layout.title)
    }

    func testWindowsTooNarrowForASwitcherKeepTheStrip() {
        let layout = ChromeLayout.make(width: 120, height: 90, tabCount: 2)
        XCTAssertEqual(layout.tabMode, .strip)
        XCTAssertEqual(layout.contentTop, 54)
    }

    func testInactiveControlsRestBehindTheRightEdgeOverflow() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1)
        XCTAssertTrue(layout.fold.isEmpty)
        XCTAssertTrue(layout.edgeReveal.isEmpty)
        XCTAssertTrue(layout.spaces.isEmpty)
        XCTAssertTrue(layout.window.isEmpty)
        XCTAssertTrue(layout.lock.isEmpty)
        XCTAssertEqual(layout.overflow, ChromeLayout.lockFrame(forWidth: 280))
    }

    func testExpandedControlsSlideOutInTheirOriginalOrder() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1, controlsExpanded: true)
        XCTAssertEqual(layout.fold.width, 22)
        XCTAssertEqual(layout.edgeReveal.width, 22)
        XCTAssertEqual(layout.spaces.width, 22)
        XCTAssertEqual(layout.window.width, 22)
        XCTAssertEqual(layout.lock.width, 28)
        XCTAssertTrue(layout.overflow.isEmpty)
        XCTAssertEqual(layout.lock, ChromeLayout.lockFrame(forWidth: 280))
        XCTAssertEqual(layout.window.maxX, layout.lock.minX)
        XCTAssertEqual(layout.spaces.maxX, layout.window.minX)
        XCTAssertEqual(layout.edgeReveal.maxX, layout.spaces.minX)
        XCTAssertEqual(layout.fold.maxX, layout.edgeReveal.minX)
        for control in [layout.fold, layout.edgeReveal, layout.spaces, layout.window, layout.lock] {
            XCTAssertGreaterThanOrEqual(control.minX, 0)
            XCTAssertLessThanOrEqual(control.maxX, 280)
        }
    }

    func testEnabledSwitchesRemainVisibleWhenOverflowCollapses() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1,
                                       automaticFolding: true, allSpaces: true)
        XCTAssertFalse(layout.fold.isEmpty)
        XCTAssertFalse(layout.spaces.isEmpty)
        XCTAssertTrue(layout.edgeReveal.isEmpty)
        XCTAssertTrue(layout.window.isEmpty)
        XCTAssertTrue(layout.lock.isEmpty)
        XCTAssertEqual(layout.spaces.maxX, layout.overflow.minX)
        XCTAssertEqual(layout.fold.maxX, layout.spaces.minX)
    }

    func testNarrowExpansionMakesRoomForControlsWithoutOverlappingLeftButtons() {
        let layout = ChromeLayout.make(width: 120, height: 360, tabCount: 1,
                                       controlsExpanded: true)
        XCTAssertTrue(layout.narrow)
        XCTAssertEqual(layout.fold.width, 16)
        XCTAssertEqual(layout.edgeReveal.width, 0)
        XCTAssertEqual(layout.spaces.width, 0)
        XCTAssertEqual(layout.window.width, 16)
        XCTAssertEqual(layout.lock.width, 28)
        XCTAssertFalse(layout.close.isEmpty)
        XCTAssertFalse(layout.hide.isEmpty)
        XCTAssertTrue(layout.addTab.isEmpty)
        XCTAssertTrue(layout.title == nil)
        XCTAssertGreaterThanOrEqual(layout.fold.minX, 0)
    }

    func testEnabledDesktopSwitchRemainsVisibleInNarrowWindows() {
        let layout = ChromeLayout.make(width: 120, height: 360, tabCount: 1, allSpaces: true)
        XCTAssertEqual(layout.spaces.width, 16)
        XCTAssertEqual(layout.spaces.maxX, layout.overflow.minX - 2)
    }

    func testLockedRecoveryStaysInItsOriginalCornerAtEverySize() {
        for width in [120, 168, 220, 280, 480] as [CGFloat] {
            let layout = ChromeLayout.make(width: width, height: 360, tabCount: 1, locked: true)
            XCTAssertEqual(layout.lock, CGRect(x: width - 32, y: 0, width: 28, height: 28))
            XCTAssertEqual(layout.lock, ChromeLayout.lockFrame(forWidth: width))
            XCTAssertTrue(layout.overflow.isEmpty)
        }
        let narrow = ChromeLayout.make(width: 120, height: 90, tabCount: 1,
                                        automaticFolding: true, allSpaces: true, locked: true)
        XCTAssertFalse(narrow.fold.isEmpty)
        XCTAssertFalse(narrow.spaces.isEmpty)
        XCTAssertLessThanOrEqual(narrow.addTab.maxX, narrow.fold.minX)
    }

    func testExpandingControlsDoesNotMoveTheContentOrChangeTabMode() {
        let resting = ChromeLayout.make(width: 240, height: 150, tabCount: 2)
        let expanded = ChromeLayout.make(width: 240, height: 150, tabCount: 2,
                                         controlsExpanded: true)
        XCTAssertEqual(resting.tabMode, .switcher)
        XCTAssertEqual(expanded.tabMode, resting.tabMode)
        XCTAssertEqual(expanded.contentTop, resting.contentTop)
    }

    func testControlsNeverOverlapAndStayInsideTheWindow() {
        for width in stride(from: 120 as CGFloat, through: 480, by: 8) {
            for expanded in [false, true] {
                let layout = ChromeLayout.make(width: width, height: 360, tabCount: 1,
                                               controlsExpanded: expanded,
                                               automaticFolding: true, allSpaces: true)
                let controls = [layout.close, layout.hide, layout.addTab, layout.fold,
                                layout.edgeReveal, layout.spaces, layout.window,
                                layout.lock, layout.overflow].filter { !$0.isEmpty }
                for (index, control) in controls.enumerated() {
                    XCTAssertGreaterThanOrEqual(control.minX, 0, "width \(width)")
                    XCTAssertLessThanOrEqual(control.maxX, width, "width \(width)")
                    for other in controls[(index + 1)...] {
                        XCTAssertFalse(control.insetBy(dx: 0.5, dy: 0).intersects(other), "width \(width)")
                    }
                }
                if let title = layout.title {
                    XCTAssertGreaterThanOrEqual(title.minX, layout.addTab.maxX, "width \(width)")
                    let rightControls = [layout.fold, layout.edgeReveal, layout.spaces,
                                         layout.window, layout.lock, layout.overflow].filter { !$0.isEmpty }
                    XCTAssertLessThanOrEqual(title.maxX, rightControls.map(\.minX).min() ?? width,
                                             "width \(width)")
                }
            }
        }
    }

    func testEveryPageKindHasATitle() {
        XCTAssertEqual(PageKind.allCases.count, 5)
        XCTAssertTrue(PageKind.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(Set(PageKind.allCases.map(\.title)).count, PageKind.allCases.count)
    }
}
