import CoreGraphics
import XCTest
import OrielCore

@MainActor
final class AutomaticFoldingTests: XCTestCase {
    private let expanded = CGRect(x: 100, y: 100, width: 280, height: 360)
    private let inside = CGPoint(x: 200, y: 200)
    private let outside = CGPoint(x: 600, y: 200)
    private let bar = CGPoint(x: 200, y: 450)

    func testLeavingFoldsAndOnlyTheVisibleBarCanExpandIt() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: inside)
        XCTAssertEqual(controller.snapshot?.automaticFolding, true)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: 100, y: 432, width: 280, height: 28))
        XCTAssertEqual(controller.snapshot?.frame, expanded)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
        controller.samplePointer(inside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        controller.samplePointer(bar, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.presentationFrame, expanded)
        controller.samplePointer(inside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
    }

    func testTurningOffFoldingPinsTheExpandedWindow() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: outside)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        controller.setAutomaticFolding(false, pointer: outside)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.automaticFolding, false)
        XCTAssertEqual(controller.snapshot?.presentationFrame, expanded)
    }

    func testEditingAndGeometryKeepTheWindowExpanded() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: outside)
        controller.samplePointer(outside, for: id, editing: true)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        controller.beginGeometryChange(for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.endGeometryChange(pointer: outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
    }

    func testLockedWindowStaysExpandedWithItsRecoveryControl() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: outside)
        controller.setLocked(true)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.automaticFolding, true)
        controller.setLocked(false)
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
    }

    func testFoldingAndEdgeHidingAreExclusiveAndRecoveryClearsBoth() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticHiding(true, pointer: outside)
        controller.setAutomaticFolding(true, pointer: outside)
        XCTAssertEqual(controller.snapshot?.automaticHiding, false)
        XCTAssertEqual(controller.snapshot?.automaticFolding, true)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
        controller.setAutomaticHiding(true, pointer: outside)
        XCTAssertEqual(controller.snapshot?.automaticFolding, false)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.setAutomaticFolding(true, pointer: outside)
        controller.recover()
        controller.samplePointer(outside, for: id)
        XCTAssertEqual(controller.snapshot?.automaticFolding, false)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
        controller.setAutomaticFolding(true, pointer: outside)
        controller.hide()
        controller.samplePointer(bar, for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
        XCTAssertEqual(controller.snapshot?.automaticFolding, false)
    }

    func testFoldedFrameUpdatesKeepExpandedSizeAndUseTheNewBar() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: outside)
        let moved = CGRect(x: 400, y: 200, width: 300, height: 400)
        controller.updateFrame(moved, for: id)
        XCTAssertEqual(controller.snapshot?.frame, moved)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: 400, y: 572, width: 300, height: 28))
        controller.samplePointer(bar, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        controller.samplePointer(CGPoint(x: 500, y: 585), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.presentationFrame, moved)
    }

    func testFoldingRoutesOnlyToItsOwnerAndCannotReviveClosedWindows() throws {
        let group = WindowGroupController()
        let a = group.create(frame: expanded)
        let b = group.create(frame: expanded.offsetBy(dx: 500, dy: 0))
        let originalB = group.snapshot(for: b)
        group.send(.automaticFolding(true, pointer: outside), to: a)
        XCTAssertTrue(try XCTUnwrap(group.snapshot(for: a)).isFolded)
        XCTAssertEqual(group.snapshot(for: b), originalB)
        group.send(.close, to: a)
        group.send(.automaticFolding(true, pointer: bar), to: a)
        group.send(.pointer(bar, editing: false), to: a)
        XCTAssertNil(group.snapshot(for: a))
        XCTAssertEqual(group.snapshot(for: b), originalB)
    }

    func testBottomBarExpandsUpwardAndReturnsToTheSameBar() throws {
        let controller = WindowBehaviorController()
        controller.updateVisibleFrame(CGRect(x: 0, y: 0, width: 1000, height: 800))
        let id = controller.create(frame: CGRect(x: 100, y: -312, width: 280, height: 360))
        controller.setAutomaticFolding(true, pointer: CGPoint(x: 900, y: 700))
        let expectedBar = CGRect(x: 100, y: 20, width: 280, height: 28)
        XCTAssertEqual(controller.snapshot?.presentationFrame, expectedBar)
        XCTAssertEqual(controller.snapshot?.foldingEdge, .bottom)
        for _ in 0..<3 {
            controller.samplePointer(CGPoint(x: 200, y: 34), for: id)
            XCTAssertEqual(controller.snapshot?.isFolded, false)
            XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: 100, y: 20, width: 280, height: 360))
            controller.samplePointer(CGPoint(x: 900, y: 700), for: id)
            XCTAssertEqual(controller.snapshot?.presentationFrame, expectedBar)
        }
    }

    func testTopBarKeepsExpandingDownwardWhenThereIsRoom() {
        let controller = WindowBehaviorController()
        controller.updateVisibleFrame(CGRect(x: 0, y: 0, width: 1000, height: 800))
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: outside)
        XCTAssertEqual(controller.snapshot?.foldingEdge, .top)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: 100, y: 432, width: 280, height: 28))
        controller.samplePointer(bar, for: id)
        XCTAssertEqual(controller.snapshot?.presentationFrame, expanded)
    }

    func testScreenChangesUseNegativeDisplayCoordinatesAndKeepTheWholeWindowVisible() throws {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: -1500, y: -212, width: 280, height: 360))
        controller.updateVisibleFrame(CGRect(x: -1600, y: 100, width: 1000, height: 700))
        controller.setAutomaticFolding(true, pointer: .zero)
        controller.samplePointer(CGPoint(x: -1400, y: 134), for: id)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: -1500, y: 120, width: 280, height: 360))
        controller.updateVisibleFrame(CGRect(x: -1600, y: 100, width: 220, height: 200))
        controller.samplePointer(CGPoint(x: -1500, y: 150), for: id, editing: true)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: -1600, y: 100, width: 220, height: 200))
    }

    func testMovingAnExpandedWindowToTheBottomFitsItAfterDraggingEnds() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.updateVisibleFrame(CGRect(x: 0, y: 0, width: 1000, height: 800))
        controller.setAutomaticFolding(true, pointer: inside)
        controller.beginGeometryChange(for: id)
        let moved = CGRect(x: 100, y: -312, width: 280, height: 360)
        controller.updateFrame(moved, for: id)
        XCTAssertEqual(controller.snapshot?.frame, moved)
        controller.endGeometryChange(pointer: CGPoint(x: 200, y: 34), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.frame, CGRect(x: 100, y: 20, width: 280, height: 360))
        XCTAssertEqual(controller.snapshot?.foldedFrame, CGRect(x: 100, y: 20, width: 280, height: 28))
    }

    func testFastEntryAcrossTopBarExpandsWithoutLandingOnTheBar() {
        let controller = WindowBehaviorController()
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        controller.updateVisibleFrame(screen)
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: CGPoint(x: 200, y: 500))
        controller.samplePointer(CGPoint(x: 200, y: 500), for: id)
        controller.updateVisibleFrame(screen) // The native adapter reports this before each sample.
        controller.samplePointer(CGPoint(x: 200, y: 420), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        controller.samplePointer(inside, for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
    }

    func testFirstFastEntryUsesThePointerFromEnablingFolding() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: CGPoint(x: 200, y: 500))
        controller.samplePointer(CGPoint(x: 200, y: 420), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
    }

    func testFastEntryAcrossBottomBarExpandsUpward() {
        let controller = WindowBehaviorController()
        controller.updateVisibleFrame(CGRect(x: 0, y: 0, width: 1000, height: 800))
        let id = controller.create(frame: CGRect(x: 100, y: -312, width: 280, height: 360))
        controller.setAutomaticFolding(true, pointer: CGPoint(x: 200, y: 0))
        controller.samplePointer(CGPoint(x: 200, y: 0), for: id)
        controller.samplePointer(CGPoint(x: 200, y: 80), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, false)
        XCTAssertEqual(controller.snapshot?.presentationFrame, CGRect(x: 100, y: 20, width: 280, height: 360))
    }

    func testDiagonalAndCornerEntriesCrossTheVisibleBar() {
        for start in [CGPoint(x: 50, y: 480), CGPoint(x: 80, y: 500)] {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: expanded)
            controller.setAutomaticFolding(true, pointer: start)
            controller.samplePointer(start, for: id)
            controller.samplePointer(CGPoint(x: 120, y: 420), for: id)
            XCTAssertEqual(controller.snapshot?.isFolded, false)
        }
    }

    func testPassingBesideTheBarOrAcrossTheWholeWindowDoesNotFlashIt() {
        let paths = [
            (CGPoint(x: 500, y: 200), CGPoint(x: 200, y: 200)),
            (CGPoint(x: 200, y: 500), CGPoint(x: 200, y: 50)),
            (CGPoint(x: 385, y: 500), CGPoint(x: 385, y: 420)),
            (CGPoint(x: 50, y: 460), CGPoint(x: 120, y: 420))
        ]
        for (start, end) in paths {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: expanded)
            controller.setAutomaticFolding(true, pointer: start)
            controller.samplePointer(start, for: id)
            controller.samplePointer(end, for: id)
            XCTAssertEqual(controller.snapshot?.isFolded, true)
        }
    }

    func testMovingOrChangingDisplaysDiscardsOldFoldingPaths() {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: expanded)
        controller.setAutomaticFolding(true, pointer: CGPoint(x: 200, y: 500))
        controller.samplePointer(CGPoint(x: 200, y: 500), for: id)
        controller.updateFrame(CGRect(x: 600, y: 100, width: 280, height: 360), for: id)
        controller.samplePointer(CGPoint(x: 700, y: 420), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
        controller.samplePointer(CGPoint(x: 700, y: 500), for: id)
        controller.updateVisibleFrame(CGRect(x: 0, y: 0, width: 1200, height: 900))
        controller.samplePointer(CGPoint(x: 700, y: 420), for: id)
        XCTAssertEqual(controller.snapshot?.isFolded, true)
    }
}
