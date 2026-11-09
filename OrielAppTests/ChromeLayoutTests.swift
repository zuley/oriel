import XCTest

final class ChromeLayoutTests: XCTestCase {
    func testSingleTabKeepsTheToolbarOnlyAndContentStartsBelowIt() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1)
        XCTAssertEqual(layout.tabMode, .none)
        XCTAssertEqual(layout.contentTop, 32)
        XCTAssertEqual(layout.tabStrip.height, 0)
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
        XCTAssertNil(layout.title)
        XCTAssertEqual(layout.tabMode, .strip)
        XCTAssertEqual(layout.contentTop, 54)
    }

    func testRightSideKeepsThreeSeparateIconsInOrder() {
        let layout = ChromeLayout.make(width: 280, height: 360, tabCount: 1)
        XCTAssertEqual(layout.edgeReveal.width, 22)
        XCTAssertEqual(layout.window.width, 22)
        XCTAssertEqual(layout.lock.width, 28)
        XCTAssertEqual(layout.lock.maxX, 280 - 4)
        XCTAssertEqual(layout.window.maxX, layout.lock.minX)
        XCTAssertEqual(layout.edgeReveal.maxX, layout.window.minX)
        XCTAssertLessThanOrEqual(layout.edgeReveal.maxX, layout.window.minX)
        XCTAssertLessThanOrEqual(layout.window.maxX, layout.lock.minX)
        for control in [layout.edgeReveal, layout.window, layout.lock] {
            XCTAssertGreaterThanOrEqual(control.minX, 0)
            XCTAssertLessThanOrEqual(control.maxX, 280)
        }
    }

    func testNarrowWindowShrinksTheTwoRightSideIcons() {
        let layout = ChromeLayout.make(width: 120, height: 360, tabCount: 1)
        XCTAssertTrue(layout.narrow)
        XCTAssertEqual(layout.edgeReveal.width, 16)
        XCTAssertEqual(layout.window.width, 16)
        // The lock keeps its fixed 28 × 28 corner hit target at every width.
        XCTAssertEqual(layout.lock.width, 28)
        XCTAssertEqual(layout.window.maxX, layout.lock.minX - 2)
        XCTAssertEqual(layout.edgeReveal.maxX, layout.window.minX - 2)
    }

    func testLockStaysInItsOriginalCornerAtEverySize() {
        for width in [120, 168, 220, 280, 480] as [CGFloat] {
            let layout = ChromeLayout.make(width: width, height: 360, tabCount: 1)
            XCTAssertEqual(layout.lock, CGRect(x: width - 32, y: 0, width: 28, height: 28))
            XCTAssertEqual(layout.lock, ChromeLayout.lockFrame(forWidth: width))
        }
    }

    func testControlsNeverOverlapAndStayInsideTheWindow() {
        for width in stride(from: 120 as CGFloat, through: 480, by: 8) {
            let layout = ChromeLayout.make(width: width, height: 360, tabCount: 1)
            let controls = [layout.close, layout.hide, layout.addTab, layout.edgeReveal,
                            layout.window, layout.lock]
            for (index, control) in controls.enumerated() {
                XCTAssertGreaterThanOrEqual(control.minX, 0, "width \(width)")
                XCTAssertLessThanOrEqual(control.maxX, width, "width \(width)")
                for other in controls[(index + 1)...] {
                    XCTAssertFalse(control.insetBy(dx: 0.5, dy: 0).intersects(other), "width \(width)")
                }
            }
            if let title = layout.title {
                XCTAssertGreaterThanOrEqual(title.minX, layout.addTab.maxX, "width \(width)")
                XCTAssertLessThanOrEqual(title.maxX, layout.edgeReveal.minX, "width \(width)")
            }
        }
    }

    func testEveryPageKindHasATitle() {
        XCTAssertEqual(PageKind.allCases.count, 5)
        XCTAssertTrue(PageKind.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(Set(PageKind.allCases.map(\.title)).count, PageKind.allCases.count)
    }
}
