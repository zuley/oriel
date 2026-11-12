import SwiftUI

@main
struct OrielApp: App {
    @NSApplicationDelegateAdaptor(OrielAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Button("打开 Oriel") { model.showManagement() }
            Button("新建小窗") { model.create() }
            Divider()
            if !model.windows.isEmpty {
                Menu("恢复小窗") {
                    ForEach(model.windows) { window in
                        RecoveryMenuItem(window: window)
                    }
                }
                Divider()
            }
            Button("退出 Oriel") { model.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel("Oriel")
                .help("Oriel · 半窗")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showManagement(section: .settings) }.keyboardShortcut(",")
            }
            CommandMenu("小窗") {
                WindowActions(model: model)
            }
        }
    }

    private static let menuBarIcon: NSImage = {
        let image = Bundle.main.url(forResource: "OrielMenuTemplate", withExtension: "pdf", subdirectory: "Brand")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Oriel")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

private struct WindowActions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("新建小窗") { model.create() }
        ForEach(model.windows) { window in
            IndividualWindowMenu(window: window)
        }
    }
}

private struct RecoveryMenuItem: View {
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Button(window.name) {
            if window.needsTransparencyRecovery { window.findWindow() }
            else { window.recover() }
        }
    }
}

private struct IndividualWindowMenu: View {
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Menu(window.name) { IndividualWindowActions(window: window) }
    }
}

private struct IndividualWindowActions: View {
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Toggle("锁定穿透", isOn: Binding(get: { window.snapshot?.isLocked ?? false }, set: window.setLocked))
        Toggle("悬停展开", isOn: Binding(get: { window.snapshot?.automaticFolding ?? false }, set: window.setAutomaticFolding))
        Toggle("边缘唤醒", isOn: Binding(get: { window.snapshot?.automaticHiding ?? false }, set: window.setAutomaticHiding))
        Toggle("在所有桌面显示", isOn: Binding(get: { window.appearsOnAllSpaces }, set: window.setAppearsOnAllSpaces))
        Button("恢复小窗") { window.recover() }
        Button("关闭小窗") { window.close() }
    }
}

@MainActor
final class OrielAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppModel.shared.preferences.openAtLaunch { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Present after SwiftUI has finished configuring the menu-bar scene.
        DispatchQueue.main.async {
            if AppModel.shared.preferences.openAtLaunch { AppModel.shared.showManagement() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showManagement()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // One question for every window's running terminal commands, before saving notes.
        let busy = AppModel.shared.windows.flatMap(\.busyTerminalTitles)
        if let message = CloseGuard.message(busy: busy) {
            let alert = NSAlert()
            alert.window.level = .statusBar
            alert.messageText = "终端中有任务正在运行"
            alert.informativeText = message.replacingOccurrences(of: "关闭会", with: "退出 Oriel 会")
            alert.addButton(withTitle: "结束并退出")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            NSApp.activate()
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return NotesWorkspace.shared.confirmCanClose() ? .terminateNow : .terminateCancel
    }
}
