import AppKit
import Darwin
import OrielTerminal
import XCTest

/// R04: closing asks for confirmation only while a command is running.
final class ForegroundJobTests: XCTestCase {
    @MainActor
    func testForegroundJobIsReportedOnlyWhileACommandRuns() async throws {
        _ = NSApplication.shared
        let terminal = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertTrue(terminal.launchShell())
        defer { terminal.endSession() }

        func wait(until expected: Bool) async throws {
            for _ in 0..<100 {
                if terminal.hasForegroundJob == expected { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("hasForegroundJob stayed \(!expected)")
        }
        try await wait(until: false)
        terminal.process.send(data: ArraySlice("/bin/sleep 30\n".utf8))
        try await wait(until: true)
        terminal.process.send(data: [3]) // Ctrl-C
        try await wait(until: false)
    }
}
