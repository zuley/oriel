import SwiftUI

@main
struct OrielApp: App {
    @NSApplicationDelegateAdaptor(OrielAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @ObservedObject private var l10n = Localization.shared

    var body: some Scene {
        MenuBarExtra {
            Button(L("打开 Oriel")) { model.showManagement() }
            Button(L("新建小窗")) { model.create() }
            Divider()
            if !model.windows.isEmpty {
                Menu(L("恢复小窗")) {
                    ForEach(model.windows) { window in
                        RecoveryMenuItem(window: window)
                    }
                }
                Divider()
            }
            Button(L("退出 Oriel")) { model.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel("Oriel")
                .help(L("Oriel · 半窗"))
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…")) { model.showManagement(section: .settings) }.keyboardShortcut(",")
            }
            CommandMenu(L("小窗")) {
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
    @ObservedObject private var l10n = Localization.shared
    @ObservedObject var model: AppModel

    var body: some View {
        Button(L("新建小窗")) { model.create() }
        ForEach(model.windows) { window in
            IndividualWindowMenu(window: window)
        }
    }
}

private struct RecoveryMenuItem: View {
    @ObservedObject private var l10n = Localization.shared
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Button(window.name) {
            if window.needsTransparencyRecovery { window.findWindow() }
            else { window.recover() }
        }
    }
}

private struct IndividualWindowMenu: View {
    @ObservedObject private var l10n = Localization.shared
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Menu(window.name) { IndividualWindowActions(window: window) }
    }
}

private struct IndividualWindowActions: View {
    @ObservedObject private var l10n = Localization.shared
    @ObservedObject var window: MiniWindowSession
    var body: some View {
        Toggle(L("锁定穿透"), isOn: Binding(get: { window.snapshot?.isLocked ?? false }, set: window.setLocked))
        Toggle(L("悬停展开"), isOn: Binding(get: { window.snapshot?.automaticFolding ?? false }, set: window.setAutomaticFolding))
        Toggle(L("边缘唤醒"), isOn: Binding(get: { window.snapshot?.automaticHiding ?? false }, set: window.setAutomaticHiding))
        Toggle(L("在所有桌面显示"), isOn: Binding(get: { window.appearsOnAllSpaces }, set: window.setAppearsOnAllSpaces))
        Button(L("恢复小窗")) { window.recover() }
        Button(L("关闭小窗")) { window.close() }
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
        if let message = CloseGuard.message(busy: busy, intent: .quitting) {
            let alert = NSAlert()
            alert.window.level = .statusBar
            alert.messageText = L("终端中有任务正在运行")
            alert.informativeText = message
            alert.addButton(withTitle: L("结束并退出"))
            alert.addButton(withTitle: L("取消")).keyEquivalent = "\u{1b}"
            NSApp.activate()
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return NotesWorkspace.shared.confirmCanClose() ? .terminateNow : .terminateCancel
    }
}
