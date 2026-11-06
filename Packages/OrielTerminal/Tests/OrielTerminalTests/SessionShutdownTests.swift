import AppKit
import Darwin
import OrielTerminal
import XCTest

final class SessionShutdownTests: XCTestCase {
    @MainActor
    func testCloseEndsForegroundJobIgnoringHangup() async throws {
        try await verifyShutdown(quittingApp: false)
    }

    @MainActor
    func testQuitFlushesPendingJobShutdown() async throws {
        try await verifyShutdown(quittingApp: true)
    }

    @MainActor
    private func verifyShutdown(quittingApp: Bool) async throws {
        _ = NSApplication.shared
        let terminal = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertTrue(terminal.launchShell())
        defer { terminal.endSession() }

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = "/bin/sh -c 'trap \"\" HUP TERM; echo $$ > \"$1\"; exec /bin/sleep 10' sh \"\(marker.path)\"\n"
        terminal.process.send(data: ArraySlice(command.utf8))
        var child: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                child = pid
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try XCTUnwrap(child)
        let session = terminal.process.shellPid
        defer { if getsid(pid) == session { kill(pid, SIGKILL) } }
        XCTAssertEqual(tcgetpgrp(terminal.process.childfd), getpgid(pid))
        terminal.endSession()
        if quittingApp { ShellTerminalView.finishPendingShutdowns() }
        for _ in 0..<60 {
            if getsid(pid) != session && !terminal.isRunning { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Closing session \(session) left child \(pid) in session \(getsid(pid)) or shell running \(terminal.isRunning)")
    }
}
