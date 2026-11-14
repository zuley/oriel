import AppKit
import OrielTerminal

/// A login shell in the user's home directory. Returning home keeps the session;
/// `exit` ends the page and sends its tab home.
@MainActor
final class TerminalPage: TabPage {
    let kind = PageKind.terminal
    let surface = PageSurface.terminal
    private let terminal: ShellTerminalView
    private weak var host: PageHost?
    var view: NSView { terminal }
    var title: String { terminal.workingDirectoryName ?? "终端" }
    /// A command, not just the idle shell, owns the terminal.
    var isBusy: Bool { terminal.hasForegroundJob }
    var isFinished: Bool { !terminal.isRunning }
    /// The shell process, for the workspace resource readout.
    var shellPID: pid_t { terminal.shellPID }

    init(host: PageHost, frame: NSRect) {
        self.host = host
        terminal = ShellTerminalView(frame: frame)
    }

    func didOpen() {
        // The tab title follows the shell's working directory.
        terminal.onTitleChange = { [weak self] in
            guard let self else { return }
            self.host?.pageTitleChanged(self)
        }
        terminal.onExit = { [weak self] in
            guard let self else { return }
            self.terminal.removeFromSuperview()
            self.host?.pageFinished(self)
        }
        if !terminal.launchShell() {
            terminal.feed(text: "无法启动 Shell。返回首页后可重试。")
        }
    }

    func didActivate() {
        terminal.nativeBackgroundColor = OrielPalette.terminal
        terminal.nativeForegroundColor = OrielPalette.terminalInk
        host?.hostWindow.makeFirstResponder(terminal)
    }

    func hasEditingFocus(_ responder: NSResponder) -> Bool { responder === terminal }

    func dispose() {
        terminal.endSession()
        terminal.removeFromSuperview()
    }
}
