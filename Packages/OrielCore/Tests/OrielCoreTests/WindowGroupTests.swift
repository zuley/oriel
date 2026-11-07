import XCTest
import OrielCore

@MainActor
final class WindowGroupTests: XCTestCase {
    func testHoverHighlightsOnlyTargetAndRestoresWithoutChangingWindowState() {
        let group = WindowGroupController()
        let a = group.create(frame: CGRect(x: 100, y: 100, width: 280, height: 360))
        let b = group.create(frame: CGRect(x: 500, y: 100, width: 280, height: 360))
        group.send(.setLocked(true), to: a)
        let original = group.snapshots
        group.hover(a)
        XCTAssertEqual(group.emphasis(for: a), .highlighted)
        XCTAssertEqual(group.emphasis(for: b), .dimmed)
        group.hover(b)
        group.endHover(a) // A delayed exit must not clear the new row.
        XCTAssertEqual(group.emphasis(for: a), .dimmed)
        XCTAssertEqual(group.emphasis(for: b), .highlighted)
        group.endHover(b)
        XCTAssertEqual(group.emphasis(for: a), .normal)
        XCTAssertEqual(group.emphasis(for: b), .normal)
        XCTAssertEqual(group.snapshots, original)
    }

    func testHiddenClosedAndMissingHoverTargetsNeverLeaveOtherWindowsDimmed() {
        let group = WindowGroupController()
        let a = group.create(frame: CGRect(x: 100, y: 100, width: 280, height: 360))
        let b = group.create(frame: CGRect(x: 500, y: 100, width: 280, height: 360))
        group.hover(a)
        group.send(.hide, to: a)
        XCTAssertEqual(group.emphasis(for: b), .normal)
        group.hover(a)
        XCTAssertEqual(group.emphasis(for: a), .normal)
        group.send(.recover, to: a)
        XCTAssertEqual(group.emphasis(for: b), .normal)
        group.hover(a)
        let c = group.create(frame: .zero)
        XCTAssertEqual(group.emphasis(for: c), .dimmed)
        group.send(.close, to: a)
        XCTAssertEqual(group.emphasis(for: b), .normal)
        group.hover(a) // Stale row callback after closing.
        XCTAssertEqual(group.emphasis(for: b), .normal)
        group.hover(b)
        group.hover(nil) // Leaving the workbench clears all effects.
        XCTAssertEqual(group.emphasis(for: b), .normal)
        XCTAssertEqual(group.emphasis(for: c), .normal)
    }

    func testCreatingAgainKeepsBothWindowsAndCommandsOnlyAffectTheirTarget() throws {
        let group = WindowGroupController()
        let first = group.create(frame: CGRect(x: 100, y: 100, width: 280, height: 360))
        let second = group.create(frame: CGRect(x: 500, y: 100, width: 280, height: 360))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(group.snapshots.map(\.id), [first, second])
        let originalSecond = try XCTUnwrap(group.snapshot(for: second))
        group.send(.setLocked(true), to: first)
        group.send(.hide, to: first)
        XCTAssertTrue(try XCTUnwrap(group.snapshot(for: first)).isLocked)
        XCTAssertFalse(try XCTUnwrap(group.snapshot(for: first)).isVisible)
        XCTAssertEqual(group.snapshot(for: second), originalSecond)
    }
    func testAutoHidingGeometryAndLateEventsStayIsolatedAcrossCloseAndRecreate() throws {
        let group = WindowGroupController()
        let a = group.create(frame: CGRect(x: 100, y: 100, width: 280, height: 360))
        let b = group.create(frame: CGRect(x: 500, y: 100, width: 280, height: 360))
        group.send(.automaticHiding(true, pointer: .zero), to: a)
        group.send(.pointer(CGPoint(x: 100, y: 120), editing: false), to: a)
        XCTAssertTrue(try XCTUnwrap(group.snapshot(for: a)).isVisible)
        XCTAssertFalse(try XCTUnwrap(group.snapshot(for: b)).automaticHiding)
        group.send(.beginGeometry, to: a)
        group.send(.frame(CGRect(x: 200, y: 200, width: 300, height: 400)), to: a)
        group.send(.endGeometry(pointer: .zero), to: a)
        XCTAssertFalse(try XCTUnwrap(group.snapshot(for: a)).isVisible)
        group.send(.recover, to: a)
        XCTAssertFalse(try XCTUnwrap(group.snapshot(for: a)).automaticHiding)
        XCTAssertEqual(try XCTUnwrap(group.snapshot(for: b)).frame.origin, CGPoint(x: 500, y: 100))
        group.send(.close, to: a)
        let c = group.create(frame: CGRect(x: 900, y: 100, width: 280, height: 360))
        let expected = group.snapshots
        group.send(.pointer(CGPoint(x: 100, y: 120), editing: false), to: a)
        group.send(.recover, to: a)
        group.send(.frame(.zero), to: a)
        group.send(.close, to: a)
        XCTAssertEqual(group.snapshots, expected)
        XCTAssertEqual(group.snapshots.map(\.id), [b, c])
        XCTAssertNil(group.snapshot(for: a))
    }

}
