import XCTest
@testable import OrielTerminal

@MainActor
final class WorkingDirectoryTests: XCTestCase {
    func testTabNameIsTheLastPathComponentOfTheReportedDirectory() {
        XCTAssertEqual(ShellTerminalView.directoryName(from: "file://mac.local/Users/me/Projects/oriel"), "oriel")
        XCTAssertEqual(ShellTerminalView.directoryName(from: "file://mac.local/Users/me/My%20Notes/"), "My Notes")
        XCTAssertEqual(ShellTerminalView.directoryName(from: "/tmp/build"), "build")
        XCTAssertEqual(ShellTerminalView.directoryName(from: "file://host/"), "/")
    }

    func testHomeShowsAsATildeAndMissingReportsGiveNoName() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ShellTerminalView.directoryName(from: "file://host" + home), "~")
        XCTAssertNil(ShellTerminalView.directoryName(from: nil))
        XCTAssertNil(ShellTerminalView.directoryName(from: ""))
    }

    func testBarePathsKeepLiteralPercentEscapes() {
        XCTAssertEqual(ShellTerminalView.directoryName(from: "/tmp/alpha%2Fbeta"), "alpha%2Fbeta")
        XCTAssertEqual(ShellTerminalView.directoryName(from: "/tmp/literal%20space"), "literal%20space")
    }

    func testShellDirectoryReportsRoundTripSpecialNames() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let startup = repository.appendingPathComponent("OrielApp/Resources/OrielZsh/.zshenv")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for name in ["alpha%2Fbeta", "literal%20space", "My Notes", "目录 #?+%&", "line\nbreak", "bell\u{7}escape\u{1b}"] {
            let directory = temporary.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-dfc", "source \"$1\"; builtin cd -- \"$2\"; _oriel_report_cwd", "oriel-cwd-test", startup.path, directory.path]
            // Source only the bundled hook, never the user's startup files.
            shell.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                 "ORIEL_ORIGINAL_ZDOTDIR": temporary.path, "ZDOTDIR": temporary.path]
            let output = Pipe()
            shell.standardOutput = output
            try shell.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0)
            let report = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(report.hasPrefix("\u{1b}]7;"))
            XCTAssertTrue(report.hasSuffix("\u{7}"))
            let uri = String(report.dropFirst(4).dropLast())
            XCTAssertFalse(uri.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            XCTAssertEqual(ShellTerminalView.directoryName(from: uri), name)
        }
    }
}
