import Foundation
import CoreGraphics
import XCTest
import OrielCore

final class WindowBehaviorControllerTests: XCTestCase {
    @MainActor
    func testOrdinaryLockingPreservesPointerHistoryForFastEntry() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        controller.setLocked(true)
        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
    }

    @MainActor
    func testEndingGeometryChangePreservesVisibilityInsideOrWhenAutomaticHidingIsOff() async {
        let scenarios: [(automatic: Bool, end: CGPoint, afterSampleVisible: Bool)] = [
            (true, CGPoint(x: 550, y: 150), false),
            (false, CGPoint(x: 80, y: 150), true)
        ]
        for scenario in scenarios {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
            controller.setAutomaticHiding(scenario.automatic, pointer: CGPoint(x: 150, y: 150))
            controller.beginGeometryChange(for: id)
            controller.updateFrame(CGRect(x: 500, y: 100, width: 400, height: 300), for: id)

            controller.endGeometryChange(pointer: scenario.end, for: id)

            XCTAssertEqual(controller.snapshot?.isVisible, true)
            XCTAssertEqual(controller.snapshot?.automaticHiding, scenario.automatic)
            controller.samplePointer(CGPoint(x: 80, y: 150), for: id)
            XCTAssertEqual(controller.snapshot?.isVisible, scenario.afterSampleVisible)
        }
    }

    @MainActor
    func testOldGeometryCommandsCannotInterruptCurrentWindowGesture() async {
        let controller = WindowBehaviorController()
        let oldID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.close()
        let currentID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))
        controller.beginGeometryChange(for: currentID)

        controller.beginGeometryChange(for: oldID)
        controller.endGeometryChange(pointer: CGPoint(x: 80, y: 150), for: oldID)
        controller.samplePointer(CGPoint(x: 80, y: 150), for: currentID)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        controller.endGeometryChange(pointer: CGPoint(x: 80, y: 150), for: currentID)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testLockingInterruptsGeometryChangeAndResumesAutomaticHiding() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))
        controller.beginGeometryChange(for: id)

        controller.setLocked(true)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, true)
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
    }

    @MainActor
    func testHideRecoveryAndCloseEndGeometryChanges() async {
        for action in ["hide", "recover", "close"] {
            let controller = WindowBehaviorController()
            var id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
            controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))
            controller.beginGeometryChange(for: id)

            switch action {
            case "hide": controller.hide()
            case "recover": controller.recover()
            default:
                controller.close()
                id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
            }
            controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))
            controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

            XCTAssertEqual(controller.snapshot?.isVisible, false, "After \(action)")
        }
    }

    @MainActor
    func testHiddenOrLockedWindowsCannotBeginGeometryChanges() async {
        let scenarios: [(locked: Bool, initial: CGPoint, sample: CGPoint, visible: Bool)] = [
            (true, CGPoint(x: 150, y: 150), CGPoint(x: 80, y: 150), false),
            (false, CGPoint(x: 80, y: 150), CGPoint(x: 95, y: 150), true)
        ]
        for scenario in scenarios {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
            controller.setAutomaticHiding(true, pointer: scenario.initial)
            controller.setLocked(scenario.locked)

            controller.beginGeometryChange(for: id)
            controller.samplePointer(scenario.sample, for: id)

            XCTAssertEqual(controller.snapshot?.isVisible, scenario.visible)
        }
    }

    @MainActor
    func testEndingGeometryChangeUsesFinalFrameAndCurrentPointer() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480), opacity: 0.4)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))
        controller.beginGeometryChange(for: id)
        controller.updateFrame(CGRect(x: 500, y: 100, width: 400, height: 300), for: id)

        controller.endGeometryChange(pointer: CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
        XCTAssertEqual(controller.snapshot?.automaticHiding, true)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
        controller.samplePointer(CGPoint(x: 495, y: 150), for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
    }

    @MainActor
    func testGeometryChangeKeepsVisibleWindowOpenWhilePointerLeaves() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480), opacity: 0.4)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))

        controller.beginGeometryChange(for: id)
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, true)
        XCTAssertEqual(controller.snapshot?.isLocked, false)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
    }

    @MainActor
    func testInvalidFrameChangesPreserveStateAndPointerHistory() async {
        let invalidFrames: [CGRect] = [
            CGRect(x: 100, y: 100, width: 0, height: 480),
            CGRect(x: 100, y: 100, width: -10, height: 480),
            CGRect(x: 100, y: 100, width: 320, height: 0),
            CGRect(x: 100, y: 100, width: 320, height: -10),
            CGRect(x: CGFloat.nan, y: 100, width: 320, height: 480),
            CGRect(x: 100, y: CGFloat.infinity, width: 320, height: 480),
            CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 480),
            CGRect(x: 100, y: 100, width: 320, height: CGFloat.nan)
        ]
        for frame in invalidFrames {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
            controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
            controller.samplePointer(CGPoint(x: 80, y: 150), for: id)
            let before = controller.snapshot

            controller.updateFrame(frame, for: id)

            XCTAssertEqual(controller.snapshot, before, "Rejected frame: \(frame)")
            controller.samplePointer(CGPoint(x: 150, y: 150), for: id)
            XCTAssertEqual(controller.snapshot?.isVisible, true)
        }
    }

    @MainActor
    func testUnchangedFramePreservesPointerHistoryForFastEntry() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        controller.updateFrame(CGRect(x: 100, y: 100, width: 320, height: 480), for: id)
        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
    }

    @MainActor
    func testChangedFrameDiscardsPointerHistoryFromPreviousGeometry() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        controller.updateFrame(CGRect(x: 500, y: 100, width: 400, height: 300), for: id)
        controller.samplePointer(CGPoint(x: 550, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testFrameChangesFromClosedWindowCannotMoveNewWindow() async {
        let controller = WindowBehaviorController()
        let oldID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        controller.close()
        let newID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))
        let before = controller.snapshot

        controller.updateFrame(CGRect(x: 500, y: 100, width: 400, height: 300), for: oldID)

        XCTAssertEqual(controller.snapshot, before)
        XCTAssertEqual(controller.snapshot?.id, newID)
    }

    @MainActor
    func testUpdatedFrameMovesWakeZoneAndPreservesWindowConfiguration() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480), opacity: 0.4)
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.updateFrame(CGRect(x: 500, y: 100, width: 400, height: 300), for: id)

        XCTAssertEqual(controller.snapshot?.frame, CGRect(x: 500, y: 100, width: 400, height: 300))
        XCTAssertEqual(controller.snapshot?.id, id)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, true)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
        controller.samplePointer(CGPoint(x: 95, y: 150), for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
        controller.samplePointer(CGPoint(x: 495, y: 150), for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
    }

    @MainActor
    func testHidePreservesWindowConfigurationAndPreventsPointerReveal() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480), opacity: 0.4)
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))

        controller.hide()
        controller.samplePointer(CGPoint(x: 95, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.id, id)
        XCTAssertEqual(controller.snapshot?.frame, CGRect(x: 100, y: 100, width: 320, height: 480))
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, false)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testReenablingAutomaticHidingStartsWithoutOldPointerHistory() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 240))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)
        controller.setAutomaticHiding(false, pointer: CGPoint(x: 80, y: 150))

        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testFastPointerEntryAcrossEdgeWakesWindow() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 240), opacity: 0.4)
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)
        XCTAssertEqual(controller.snapshot?.isVisible, false)

        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
    }

    @MainActor
    func testFastPassAcrossEntireWindowDoesNotFlashIt() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 240))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        controller.samplePointer(CGPoint(x: 450, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testCreatedWindowStartsVisibleUnlockedWithoutAutomaticHiding() async {
        let controller = WindowBehaviorController()

        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 480))

        XCTAssertEqual(controller.snapshot?.id, id)
        XCTAssertEqual(controller.snapshot?.frame, CGRect(x: 100, y: 100, width: 320, height: 480))
        XCTAssertEqual(controller.snapshot?.opacity, 1)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, false)
        XCTAssertEqual(controller.snapshot?.automaticHiding, false)
    }

    @MainActor
    func testLockChangesPreserveVisibilityAndAutomaticHiding() async {
        let scenarios: [(automatic: Bool, point: CGPoint, visible: Bool)] = [
            (false, CGPoint(x: 80, y: 150), true),
            (true, CGPoint(x: 80, y: 150), false),
            (true, CGPoint(x: 150, y: 150), true)
        ]
        for scenario in scenarios {
            let controller = WindowBehaviorController()
            controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120), opacity: 0.4)
            controller.setAutomaticHiding(scenario.automatic, pointer: scenario.point)

            controller.setLocked(true)
            XCTAssertEqual(controller.snapshot?.isLocked, true)
            XCTAssertEqual(controller.snapshot?.isVisible, scenario.visible)
            XCTAssertEqual(controller.snapshot?.automaticHiding, scenario.automatic)

            controller.setLocked(false)
            XCTAssertEqual(controller.snapshot?.isLocked, false)
            XCTAssertEqual(controller.snapshot?.isVisible, scenario.visible)
            XCTAssertEqual(controller.snapshot?.automaticHiding, scenario.automatic)
            XCTAssertEqual(controller.snapshot?.opacity, 0.4)
        }
    }

    @MainActor
    func testLeavingAnySideHidesWindowAndRepeatedOutsideSamplesDoNotWakeIt() async {
        let outsidePoints: [CGPoint] = [
            CGPoint(x: 87.9, y: 150), CGPoint(x: 312.1, y: 150),
            CGPoint(x: 150, y: 87.9), CGPoint(x: 150, y: 232.1),
            CGPoint(x: 80, y: 150)
        ]
        for point in outsidePoints {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
            controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))

            controller.samplePointer(point, for: id)
            XCTAssertEqual(controller.snapshot?.isVisible, false, "Outside point: \(point)")
            controller.samplePointer(point, for: id)
            XCTAssertEqual(controller.snapshot?.isVisible, false, "Repeated outside point: \(point)")
        }
    }

    @MainActor
    func testAllOuterAndInnerBoundariesCanWakeHiddenWindow() async {
        let edgePoints: [CGPoint] = [
            CGPoint(x: 88, y: 150), CGPoint(x: 312, y: 150),
            CGPoint(x: 150, y: 88), CGPoint(x: 150, y: 232),
            CGPoint(x: 88, y: 88), CGPoint(x: 88, y: 232),
            CGPoint(x: 312, y: 88), CGPoint(x: 312, y: 232),
            CGPoint(x: 112, y: 150), CGPoint(x: 288, y: 150),
            CGPoint(x: 150, y: 112), CGPoint(x: 150, y: 208),
            CGPoint(x: 112, y: 112), CGPoint(x: 112, y: 208),
            CGPoint(x: 288, y: 112), CGPoint(x: 288, y: 208),
            CGPoint(x: 105, y: 150)
        ]
        for point in edgePoints {
            let controller = WindowBehaviorController()
            let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
            controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

            controller.samplePointer(point, for: id)

            XCTAssertEqual(controller.snapshot?.isVisible, true, "Boundary point: \(point)")
        }
    }

    @MainActor
    func testPointerSamplesCannotHideRecoveredWindow() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.recover()

        controller.samplePointer(CGPoint(x: 80, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
    }

    @MainActor
    func testDisablingAutomaticHidingShowsWindowWithoutUnlockingIt() async {
        let controller = WindowBehaviorController()
        controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.setAutomaticHiding(false, pointer: CGPoint(x: 80, y: 150))

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, false)
    }

    @MainActor
    func testEnablingAutomaticHidingKeepsWindowVisibleUnderPointer() async {
        let controller = WindowBehaviorController()
        controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))

        controller.setAutomaticHiding(true, pointer: CGPoint(x: 150, y: 150))

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.automaticHiding, true)
    }

    @MainActor
    func testRevealedWindowRemainsVisibleWhenPointerMovesIntoContent() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 95, y: 150), for: id)

        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
    }

    @MainActor
    func testHiddenWindowDoesNotWakeWhenFirstSampleIsAtCenter() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.samplePointer(CGPoint(x: 150, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testCreatingWhileWindowExistsPreservesItsConfiguration() async {
        let controller = WindowBehaviorController()
        let firstID = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120), opacity: 0.4)
        controller.setLocked(true)
        let before = controller.snapshot

        let secondID = controller.create(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(controller.snapshot, before)
    }

    @MainActor
    func testRecreatedWindowIgnoresSamplesFromClosedWindow() async {
        let controller = WindowBehaviorController()
        let oldID = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.close()
        let newID = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.samplePointer(CGPoint(x: 95, y: 150), for: oldID)

        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(controller.snapshot?.id, newID)
        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testOldWindowSamplesCannotArmNewWindowForCentralReveal() async {
        let controller = WindowBehaviorController()
        let oldID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 240))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        controller.samplePointer(CGPoint(x: 80, y: 150), for: oldID)
        controller.close()
        let newID = controller.create(frame: CGRect(x: 100, y: 100, width: 320, height: 240))
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.samplePointer(CGPoint(x: 80, y: 150), for: oldID)
        controller.samplePointer(CGPoint(x: 150, y: 150), for: newID)

        XCTAssertEqual(controller.snapshot?.isVisible, false)
    }

    @MainActor
    func testClosedWindowCannotBeRevivedByPointerOrRecovery() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120))
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.close()
        controller.samplePointer(CGPoint(x: 95, y: 150), for: id)
        controller.recover()

        XCTAssertNil(controller.snapshot)
    }

    @MainActor
    func testRecoveryShowsUnlocksAndDisablesAutomaticHiding() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120), opacity: 0.4)
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))

        controller.recover()

        XCTAssertEqual(controller.snapshot?.id, id)
        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, false)
        XCTAssertEqual(controller.snapshot?.automaticHiding, false)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
    }

    @MainActor
    func testLockedHiddenWindowRevealsAtEdgeWithoutLosingLockOrOpacity() async {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: CGRect(x: 100, y: 100, width: 200, height: 120), opacity: 0.4)
        controller.setLocked(true)
        controller.setAutomaticHiding(true, pointer: CGPoint(x: 80, y: 150))
        XCTAssertEqual(controller.snapshot?.isVisible, false)

        controller.samplePointer(CGPoint(x: 95, y: 150), for: id)

        XCTAssertEqual(controller.snapshot?.isVisible, true)
        XCTAssertEqual(controller.snapshot?.isLocked, true)
        XCTAssertEqual(controller.snapshot?.opacity, 0.4)
    }
}
