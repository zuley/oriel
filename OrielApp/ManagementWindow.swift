import AppKit
import SwiftUI

@MainActor
final class ManagementState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case workspace = "工作台", settings = "设置"
        var id: Self { self }
        var icon: String {
            switch self {
            case .workspace: "rectangle.on.rectangle"
            case .settings: "slider.horizontal.3"
            }
        }
    }
    @Published var section: Section = .workspace
    @Published var isPresented = false
}

@MainActor
final class ManagementWindow: NSWindowController, NSWindowDelegate {
    let state = ManagementState()
    private weak var model: AppModel?

    init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        self.model = model
        window.title = "Oriel"
        window.backgroundColor = OrielPalette.sidebar
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.setFrameAutosaveName("OrielManagement")
        window.contentView = NSHostingView(rootView: ManagementView(model: model, state: state))
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(section: ManagementState.Section? = nil) {
        if let section { state.section = section }
        state.isPresented = true
        NSApp.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        state.isPresented = false
        model?.clearWindowHover()
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidResignKey(_ notification: Notification) { model?.clearWindowHover() }
    func windowWillMiniaturize(_ notification: Notification) {
        state.isPresented = false
        model?.clearWindowHover()
    }
    func windowDidDeminiaturize(_ notification: Notification) { state.isPresented = true }

}
