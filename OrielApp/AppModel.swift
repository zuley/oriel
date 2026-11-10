import AppKit
import Combine
import OrielCore
import OrielTerminal

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let preferences = AppPreferences()
    private let library = NovelLibrary()
    private let watchlist = StockWatchlist()
    private let group = WindowGroupController()
    @Published private(set) var windows: [MiniWindowSession] = []
    private var nextWindowNumber = 1
    private var management: ManagementWindow?
    private var terminationObserver: NSObjectProtocol?
    private var editingMonitor: Any?

    init() {
        // Text fields in mini windows and their sheets get ⌘A/C/X/V/Z even while another
        // app is active, when the Edit menu does not see them (see EditingShortcuts).
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard let action = EditingShortcuts.action(for: event, responder: event.window?.firstResponder) else { return false }
                return NSApp.sendAction(action, to: nil, from: nil)
            }
            return handled ? nil : event
        }
        NotesWorkspace.shared.onSaveBlocked = { [weak self] documentIDs in
            guard let self else { return }
            if let note = NotesWorkspace.shared.list().first(where: {
                (documentIDs?.contains($0.id) ?? true) && $0.isDirty && $0.errorMessage != nil
            }),
               let window = self.windows.first(where: { $0.containsNote(note.id) }) {
                window.revealNote(note.id)
            } else {
                if self.windows.isEmpty { self.create() }
                self.windows.last?.revealUnsavedNote()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                for window in self?.windows ?? [] { window.dispose() }
                ShellTerminalView.finishPendingShutdowns()
            }
        }
    }

    func showManagement(section: ManagementState.Section? = nil) {
        if management == nil { management = ManagementWindow(model: self) }
        management?.present(section: section)
    }

    func create() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(preferences.width, visible.width), height: min(preferences.height, visible.height))
        let offset = CGFloat((nextWindowNumber - 1) % 10) * 28 + 24
        let frame = CGRect(x: max(visible.minX, visible.maxX - size.width - offset),
                           y: max(visible.minY, visible.maxY - size.height - offset),
                           width: size.width, height: size.height)
        let window = MiniWindowSession(number: nextWindowNumber, frame: frame, group: group,
            library: library, watchlist: watchlist, preferences: preferences,
            noteIsOpenElsewhere: { [weak self] note, except in
                self?.windows.contains { $0.id != except && $0.containsNote(note) } ?? false
            },
            focusNoteElsewhere: { [weak self] note, except in
                guard let window = self?.windows.first(where: { $0.id != except && $0.containsNote(note) }) else { return false }
                window.revealNote(note)
                return true
            },
            onStateChange: { [weak self] in self?.refreshWindowEmphasis() },
            onNameChange: { [weak self] in self?.objectWillChange.send() },
            onClose: { [weak self] id in
                self?.windows.removeAll { $0.id == id }
                self?.refreshWindowEmphasis()
            })
        nextWindowNumber += 1
        windows.append(window)
        refreshWindowEmphasis()
    }

    func hoverWindow(_ id: UUID, inside: Bool) {
        if inside { group.hover(id) } else { group.endHover(id) }
        refreshWindowEmphasis()
    }

    func clearWindowHover() { group.hover(nil); refreshWindowEmphasis() }

    private func refreshWindowEmphasis() {
        for window in windows { window.setEmphasis(group.emphasis(for: window.id)) }
    }

    func applyDefaults(to id: UUID) { windows.first { $0.id == id }?.applyDefaults(preferences) }
    func quit() { NSApplication.shared.terminate(nil) }

    var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "app.oriel.mac")
    }

    func exportData(to destination: URL) async throws -> URL {
        try NotesWorkspace.shared.saveAll()
        let exporter = DataExport(source: dataDirectory)
        let staging = try exporter.prepare(in: destination, preferences: DataExport.preferences(.standard))
        defer { try? FileManager.default.removeItem(at: staging) }
        try exporter.copyNotes(to: staging)
        try await library.shelf.exportSnapshot(to: staging.appending(path: "Books"))
        try Task.checkCancellation()
        return try exporter.finish(staging)
    }
}
