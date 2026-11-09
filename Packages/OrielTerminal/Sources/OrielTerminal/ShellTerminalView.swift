import AppKit
import Darwin
import SwiftTerm

@MainActor
public final class ShellTerminalView: LocalProcessTerminalView {
    public var onExit: (() -> Void)?
    /// Called when the shell reports a new working directory, so a tab can show where it is.
    public var onTitleChange: (() -> Void)?
    public private(set) var isRunning = false
    /// Last path component of the shell's current directory ("~" for home); nil until the first prompt.
    public private(set) var workingDirectoryName: String?
    private var isClosing = false
    private var closingForeground: pid_t = -1
    private static var pendingShutdowns: [ObjectIdentifier: ShellTerminalView] = [:]

    public override var needsPanelToBecomeKey: Bool { true }

    // SwiftTerm keeps its process delegate weakly, so the observer is owned here.
    private let directoryObserver = DirectoryObserver()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        installDirectoryObserver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        installDirectoryObserver()
    }

    private func installDirectoryObserver() {
        directoryObserver.onDirectory = { [weak self] directory in
            guard let self else { return }
            let name = Self.directoryName(from: directory)
            guard name != self.workingDirectoryName else { return }
            self.workingDirectoryName = name
            self.onTitleChange?()
        }
        processDelegate = directoryObserver
    }

    /// True while something other than the idle shell owns the terminal (a build, an editor, ssh...).
    public var hasForegroundJob: Bool {
        guard isRunning, !isClosing, process.shellPid > 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
    }

    /// Accepts the `file://host/path` form of OSC 7 as well as a bare path.
    static func directoryName(from reported: String?) -> String? {
        guard var path = reported, !path.isEmpty else { return nil }
        if path.hasPrefix("file://") {
            path = String(path.dropFirst(7))
            if let slash = path.firstIndex(of: "/") { path = String(path[slash...]) }
            path = path.removingPercentEncoding ?? path
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { return "/" }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

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

/// Receives the shell's OSC 7 "current directory" reports from SwiftTerm.
@MainActor
private final class DirectoryObserver: @preconcurrency LocalProcessTerminalViewDelegate {
    var onDirectory: (@MainActor (String?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory?(directory)
    }
}
