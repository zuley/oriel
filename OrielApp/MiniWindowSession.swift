import AppKit
import Combine
import OrielCore

@MainActor
final class MiniWindowSession: ObservableObject, Identifiable {
    nonisolated let id: UUID
    let number: Int
    @Published private(set) var name: String
    @Published private(set) var snapshot: WindowSnapshot?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var needsTransparencyRecovery = false
    @Published private(set) var appearsOnAllSpaces = false
    private let group: WindowGroupController
    private let onClose: (UUID) -> Void
    private let onStateChange: () -> Void
    private let onNameChange: () -> Void
    private var panel: MiniPanel?
    private var sampler: Timer?
    private var pendingMotionSample: Timer?
    private var localMotionMonitor: Any?
    private var globalMotionMonitor: Any?
    private var sampledWindowID: UUID?

    init(number: Int, frame: CGRect, group: WindowGroupController,
         library: NovelLibrary, watchlist: StockWatchlist, preferences: AppPreferences,
         noteIsOpenElsewhere: @escaping (UUID, UUID) -> Bool,
         focusNoteElsewhere: @escaping (UUID, UUID) -> Bool,
         onStateChange: @escaping () -> Void,
         onNameChange: @escaping () -> Void,
         onClose: @escaping (UUID) -> Void) {
        self.number = number
        self.name = "小窗"
        self.group = group
        self.onClose = onClose
        self.onStateChange = onStateChange
        self.onNameChange = onNameChange
        let id = group.create(frame: frame)
        self.id = id
        panel = MiniPanel(frame: frame, library: library, watchlist: watchlist, preferences: preferences, actions: .init(
            toggleLock: { [weak self] in
                guard let self else { return }
                self.setLocked(!(self.snapshot?.isLocked ?? false))
            },
            unlock: { [weak self] in self?.setLocked(false) },
            toggleAutomaticHiding: { [weak self] in
                guard let self else { return }
                self.setAutomaticHiding(!(self.snapshot?.automaticHiding ?? false))
            },
            toggleAllSpaces: { [weak self] in
                guard let self else { return }
                self.setAppearsOnAllSpaces(!self.appearsOnAllSpaces)
            },
            recover: { [weak self] in self?.recover() },
            hide: { [weak self] in self?.hide() },
            close: { [weak self] in self?.close() },
            frameChanged: { [weak self] frame in self?.windowFrameChanged(frame, for: id) },
            geometryInteractionChanged: { [weak self] active in self?.geometryInteractionChanged(active, for: id) },
            toggleAutomaticFolding: { [weak self] in
                guard let self else { return }
                self.setAutomaticFolding(!(self.snapshot?.automaticFolding ?? false))
            },
            renameWindow: { [weak self] in self?.requestRename() },
            noteIsOpenElsewhere: { note in noteIsOpenElsewhere(note, id) },
            focusNoteElsewhere: { note in focusNoteElsewhere(note, id) },
            transparencyRecoveryChanged: { [weak self] needed in
                guard let self, self.snapshot != nil else { return }
                self.needsTransparencyRecovery = needed
            }
        ))
        panel?.setWindowName(name)
        needsTransparencyRecovery = max(preferences.backgroundOpacity, preferences.contentOpacity) <= 0.05
        if let panel { group.send(.frame(panel.bodyFrame), to: id) }
        synchronize()
    }

    static func validatedName(_ text: String) -> String? {
        let name = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return !name.isEmpty && name.count <= 32 ? name : nil
    }

    func rename(_ text: String) {
        guard panel != nil, let name = Self.validatedName(text), name != self.name else { return }
        self.name = name
        panel?.setWindowName(name)
        onNameChange()
    }

    private func requestRename() {
        guard let panel, snapshot?.isVisible == true, snapshot?.isLocked == false,
              panel.attachedSheet == nil else { return }
        panel.cancelGeometryInteraction()
        geometryInteractionChanged(false, for: id)
        group.send(.pointer(NSEvent.mouseLocation, editing: true), to: id)
        synchronize()
        let alert = NSAlert()
        alert.messageText = "重命名小窗"
        alert.informativeText = "最多 32 个字"
        let save = alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let field = WindowRenameField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = name
        field.setAccessibilityLabel("窗口名称")
        field.delegate = field
        field.saveButton = save
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        panel.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: panel) { [weak self, field] response in
            if response == .alertFirstButtonReturn { self?.rename(field.stringValue) }
        }
        field.selectText(nil)
    }

    func applyDefaults(_ preferences: AppPreferences) {
        panel?.applyDefaults(preferences)
        if snapshot?.isVisible == false { refreshThumbnail(includeHidden: true) }
    }
    func setEmphasis(_ emphasis: WindowGroupController.Emphasis) { panel?.setEmphasis(emphasis) }
    func containsNote(_ id: UUID) -> Bool { panel?.containsNote(id) ?? false }
    func revealNote(_ id: UUID) {
        guard containsNote(id) else { return }
        recover()
        panel?.revealNote(id)
    }
    func revealUnsavedNote() { recover(); panel?.revealUnsavedNote() }

    private func windowFrameChanged(_ frame: CGRect, for id: UUID) {
        guard panel != nil, group.snapshot(for: id) != nil else { return }
        updateFoldingScreen()
        group.send(.frame(frame), to: id)
        synchronize()
    }

    private func geometryInteractionChanged(_ active: Bool, for id: UUID) {
        guard panel != nil, group.snapshot(for: id) != nil else { return }
        group.send(active ? .beginGeometry : .endGeometry(pointer: NSEvent.mouseLocation), to: id)
        synchronize()
    }

    func setLocked(_ locked: Bool) { group.send(.setLocked(locked), to: id); synchronize() }
    func setAppearsOnAllSpaces(_ enabled: Bool) {
        guard let panel, appearsOnAllSpaces != enabled else { return }
        panel.setAppearsOnAllSpaces(enabled)
        appearsOnAllSpaces = enabled
    }
    func setAutomaticHiding(_ enabled: Bool) {
        group.send(.automaticHiding(enabled, pointer: NSEvent.mouseLocation), to: id)
        synchronize()
    }
    func setAutomaticFolding(_ enabled: Bool) {
        if enabled { panel?.prepareForFolding() }
        updateFoldingScreen()
        group.send(.automaticFolding(enabled, pointer: NSEvent.mouseLocation), to: id)
        synchronize()
    }
    func recover() { panel?.cancelGeometryInteraction(); group.send(.recover, to: id); synchronize() }
    func findWindow() { recover(); panel?.revealTransparencySettings() }
    func hide() { group.send(.hide, to: id); synchronize() }

    func showFromWorkspace() {
        if needsTransparencyRecovery && snapshot?.isVisible == false { findWindow() }
        else if snapshot?.isVisible == false { recover() }
        else { panel?.orderFrontRegardless() }
    }

    func refreshThumbnail(includeHidden: Bool = false) {
        guard let panel, (panel.isVisible || includeHidden), !panel.isDisposed,
              snapshot?.isFolded != true else { return }
        guard let view = panel.chrome else { return }
        if includeHidden { view.layoutSubtreeIfNeeded() }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(2, 768 / bounds.width, 440 / bounds.height)
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        thumbnail = image
    }

    var busyTerminalTitles: [String] { panel?.busyTerminalTitles ?? [] }

    /// `endingJobs`: the user already agreed to end running terminal commands
    /// (for example in the management window's close confirmation).
    func close(endingJobs: Bool = false) {
        guard snapshot != nil, let panel else { return }
        if !endingJobs, let message = CloseGuard.message(busy: panel.busyTerminalTitles) {
            // The question is a sheet on this window, so it must be visible and unlocked.
            if snapshot?.isVisible != true || snapshot?.isLocked == true { recover() }
            panel.confirmEndingJobs(message, button: "结束并关闭") { [weak self] in
                self?.close(endingJobs: true)
            }
            return
        }
        guard panel.confirmCanClose() else { return }
        dispose()
    }

    /// Used after the application's save/termination gate has passed.
    func dispose() {
        guard panel != nil else { return }
        stopSampling()
        group.send(.close, to: id)
        panel?.dispose()
        panel = nil
        thumbnail = nil
        needsTransparencyRecovery = false
        synchronize()
        onClose(id)
    }
    private func synchronize() {
        let current = group.snapshot(for: id)
        if snapshot != current {
            if let previous = snapshot, let current,
               (previous.isVisible && !current.isVisible || !previous.isFolded && current.isFolded) {
                refreshThumbnail()
            }
            if let current { panel?.apply(current) }
            snapshot = current
            onStateChange()
        }
        guard let current, current.automaticHiding || current.automaticFolding else {
            stopSampling()
            return
        }
        guard sampledWindowID != current.id else { return }
        stopSampling()
        let id = current.id
        sampledWindowID = id
        let motion: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMotionMonitor = NSEvent.addGlobalMonitorForEvents(matching: motion) { [weak self] _ in
            self?.scheduleMotionSample(for: id)
        }
        localMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: motion) { [weak self] event in
            self?.scheduleMotionSample(for: id)
            return event
        }
        // A slow fallback catches focus changes and missed motion events while idle.
        // Keep the original cadence if either event monitor could not be installed.
        let interval = globalMotionMonitor != nil && localMotionMonitor != nil ? 0.25 : 0.03
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer(for: id) }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
        scheduleMotionSample(for: id)
    }

    private func scheduleMotionSample(for id: UUID) {
        guard sampledWindowID == id, pendingMotionSample == nil else { return }
        let timer = Timer(timeInterval: 0.025, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sampledWindowID == id else { return }
                self.pendingMotionSample = nil
                self.samplePointer(for: id)
            }
        }
        pendingMotionSample = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func samplePointer(for id: UUID) {
        guard sampledWindowID == id, let panel else { return }
        updateFoldingScreen()
        group.send(.pointer(NSEvent.mouseLocation, editing: panel.hasEditingFocus || panel.keepsWindowVisible), to: id)
        synchronize()
    }

    private func updateFoldingScreen() {
        if let bounds = panel?.foldingVisibleFrame { group.send(.visibleFrame(bounds), to: id) }
    }

    private func stopSampling() {
        if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
        if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
        localMotionMonitor = nil
        globalMotionMonitor = nil
        pendingMotionSample?.invalidate()
        pendingMotionSample = nil
        sampler?.invalidate()
        sampler = nil
        sampledWindowID = nil
    }
}

@MainActor
private final class WindowRenameField: NSTextField, NSTextFieldDelegate {
    weak var saveButton: NSButton?
    func controlTextDidChange(_ notification: Notification) {
        saveButton?.isEnabled = MiniWindowSession.validatedName(stringValue) != nil
    }
}
