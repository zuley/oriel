import AppKit
import Combine
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

    var workspaceVisibility: AnyPublisher<Bool, Never> {
        $section.combineLatest($isPresented)
            .map { section, presented in presented && section == .workspace }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

@MainActor
final class ManagementWindow: NSWindowController, NSWindowDelegate {
    let state = ManagementState()
    private weak var model: AppModel?
    private var sampling: AnyCancellable?

    init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        self.model = model
        window.title = "Oriel"
        window.backgroundColor = OrielPalette.sidebar
        // The sidebar and canvas run to the window edge; the sidebar brand replaces the title.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.setFrameAutosaveName("OrielManagement")
        window.contentView = NSHostingView(rootView: ManagementView(model: model, state: state))
        window.delegate = self
        sampling = state.workspaceVisibility.sink { [weak model] visible in
            if visible {
                ResourceSampler.shared.start { [weak model] in
                    (model?.windows ?? []).map { (id: $0.id, sources: $0.resourceSources) }
                }
            } else {
                ResourceSampler.shared.stop()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(section: ManagementState.Section? = nil) {
        if let section { state.section = section }
        NSApp.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if state.isPresented != visible { state.isPresented = visible }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }

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
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }
}
