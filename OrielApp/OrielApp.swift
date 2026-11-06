import SwiftUI

@main
struct OrielApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            if let window = model.snapshot {
                if window.isLocked || !window.isVisible {
                    Button("恢复小窗") { model.recover() }
                    Divider()
                }
            } else {
                Button("新建小窗") { model.create() }
                Divider()
            }
            Button("退出 Oriel") { model.quit() }
                .keyboardShortcut("q")
        } label: {
            Text("Oriel")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandMenu("小窗") {
                WindowActions(model: model)
            }
        }
    }
}

private struct WindowActions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("新建小窗") { model.create() }
            .disabled(model.snapshot != nil)
        Toggle("锁定穿透", isOn: Binding(
            get: { model.snapshot?.isLocked ?? false },
            set: { model.setLocked($0) }
        ))
        .disabled(model.snapshot == nil)
        Toggle("边缘唤醒", isOn: Binding(
            get: { model.snapshot?.automaticHiding ?? false },
            set: { model.setAutomaticHiding($0) }
        ))
        .disabled(model.snapshot == nil)
        Divider()
        Button("恢复小窗") { model.recover() }
            .disabled(model.snapshot == nil)
        Button("关闭小窗") { model.close() }
            .disabled(model.snapshot == nil)
    }
}
