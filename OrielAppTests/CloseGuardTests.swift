import XCTest

/// R04: which closes need a confirmation, and what it says.
final class CloseGuardTests: XCTestCase {
    func testOnlyBusyTerminalsNeedConfirmation() {
        XCTAssertNil(CloseGuard.message(busy: []))
        XCTAssertEqual(CloseGuard.busyTitles([]), [])
        XCTAssertEqual(CloseGuard.busyTitles([.init(title: "~", busy: false)]), [])
        XCTAssertEqual(CloseGuard.busyTitles([.init(title: "oriel", busy: true), .init(title: "~", busy: false)]), ["oriel"])
    }

    func testMessageNamesTheBusyTabs() throws {
        let one = try XCTUnwrap(CloseGuard.message(busy: ["oriel"]))
        XCTAssertTrue(one.contains("oriel"))
        let two = try XCTUnwrap(CloseGuard.message(busy: ["oriel", "~"]))
        XCTAssertTrue(two.contains("2"))
        XCTAssertTrue(two.contains("oriel") && two.contains("~"))
    }

    func testQuittingUsesADifferentActionFromClosing() throws {
        let closing = try XCTUnwrap(CloseGuard.message(busy: ["oriel"]))
        let quitting = try XCTUnwrap(CloseGuard.message(busy: ["oriel"], intent: .quitting))
        XCTAssertNotEqual(closing, quitting)
        XCTAssertTrue(quitting.contains("Oriel"))
    }
}
