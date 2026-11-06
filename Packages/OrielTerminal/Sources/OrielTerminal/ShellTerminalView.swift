import AppKit
import Darwin
import SwiftTerm

@MainActor
public final class ShellTerminalView: LocalProcessTerminalView {
    public var onExit: (() -> Void)?
    public private(set) var isRunning = false
    private var isClosing = false
    private var closingForeground: pid_t = -1
    private static var pendingShutdowns: [ObjectIdentifier: ShellTerminalView] = [:]

    public override var needsPanelToBecomeKey: Bool { true }

    public func launchShell() -> Bool {
        let accountShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let shell = [accountShell, "/bin/zsh"].compactMap { $0 }.first {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let shell else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        nativeBackgroundColor = .black
        setAccessibilityLabel("终端")
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Oriel"
        environment["SHELL"] = shell
        environment["HOME"] = home
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh",
           let startup = Bundle.main.url(forResource: "OrielZsh", withExtension: nil) {
            environment["ORIEL_ORIGINAL_ZDOTDIR"] = environment["ZDOTDIR"]
            environment["ZDOTDIR"] = startup.path
        }
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        startProcess(executable: shell, args: ["-i"],
                     environment: environment.map { "\($0.key)=\($0.value)" },
                     execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                     currentDirectory: home)
        isRunning = process.running
        return isRunning
    }

    public func endSession() {
        onExit = nil
        guard isRunning, !isClosing, process.shellPid > 0 else { return }
        isClosing = true
        let pid = process.shellPid
        closingForeground = tcgetpgrp(process.childfd)
        signalForeground(SIGHUP)
        kill(pid, SIGHUP)
        terminate()
        Self.pendingShutdowns[ObjectIdentifier(self)] = self
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(500))
            finishShutdown()
            // Keep SwiftTerm's process monitor alive until it reaps the shell.
            while isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    /// The app can exit before a closed tab's grace period has elapsed.
    public static func finishPendingShutdowns() {
        for terminal in Array(pendingShutdowns.values) { terminal.finishShutdown() }
    }

    private func finishShutdown() {
        guard Self.pendingShutdowns.removeValue(forKey: ObjectIdentifier(self)) != nil else { return }
        signalForeground(SIGKILL)
        if isRunning { kill(process.shellPid, SIGKILL) }
    }

    private func signalForeground(_ signal: Int32) {
        let group = closingForeground
        guard group > 0 else { return }
        // A pipeline's group leader may have exited while another member is still running.
        let byteCount = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard byteCount > 0 else { return }
        var members = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride)
        let bytesRead = members.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count))
        }
        let count = max(0, Int(bytesRead) / MemoryLayout<pid_t>.stride)
        if members.prefix(count).contains(where: { $0 > 0 && getsid($0) == process.shellPid && getpgid($0) == group }) {
            killpg(group, signal)
        }
    }

    public override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        isRunning = false
        super.processTerminated(source, exitCode: exitCode)
        onExit?()
    }
}
