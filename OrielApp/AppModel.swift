import AppKit
import Combine
import OrielCore
import OrielTerminal

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: WindowSnapshot?
    @Published private(set) var needsTransparencyRecovery = false
    private let behavior = WindowBehaviorController()
    private var panel: MiniPanel?
    private var sampler: Timer?
    private var pendingMotionSample: Timer?
    private var localMotionMonitor: Any?
    private var globalMotionMonitor: Any?
    private var sampledWindowID: UUID?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
                ShellTerminalView.finishPendingShutdowns()
            }
        }
    }

    func create() {
        guard behavior.snapshot == nil else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(280, visible.width), height: min(360, visible.height))
        let frame = CGRect(
            x: max(visible.minX, visible.maxX - size.width - 24),
            y: max(visible.minY, visible.maxY - size.height - 24),
            width: size.width, height: size.height
        )
        let id = behavior.create(frame: frame)
        panel = MiniPanel(frame: frame, actions: .init(
            toggleLock: { [weak self] in
                guard let self else { return }
                self.setLocked(!(self.snapshot?.isLocked ?? false))
            },
            unlock: { [weak self] in
                guard let self, self.snapshot?.id == id else { return }
                self.setLocked(false)
            },
            toggleAutomaticHiding: { [weak self] in
                guard let self else { return }
                self.setAutomaticHiding(!(self.snapshot?.automaticHiding ?? false))
            },
            recover: { [weak self] in self?.recover() },
            hide: { [weak self] in self?.hide() },
            close: { [weak self] in self?.close() },
            frameChanged: { [weak self] frame in self?.windowFrameChanged(frame, for: id) },
            geometryInteractionChanged: { [weak self] active in
                self?.geometryInteractionChanged(active, for: id)
            },
            transparencyRecoveryChanged: { [weak self] needed in
                guard let self, snapshot?.id == id, needsTransparencyRecovery != needed else { return }
                needsTransparencyRecovery = needed
            }
        ))
        if let panel { behavior.updateFrame(panel.bodyFrame, for: id) }
        synchronize()
    }

    private func windowFrameChanged(_ frame: CGRect, for id: UUID) {
        guard panel != nil, behavior.snapshot?.id == id else { return }
        behavior.updateFrame(frame, for: id)
        synchronize()
    }

    private func geometryInteractionChanged(_ active: Bool, for id: UUID) {
        guard panel != nil, behavior.snapshot?.id == id else { return }
        if active {
            behavior.beginGeometryChange(for: id)
        } else {
            behavior.endGeometryChange(pointer: NSEvent.mouseLocation, for: id)
        }
        synchronize()
    }

    func setLocked(_ locked: Bool) {
        behavior.setLocked(locked)
        synchronize()
    }

    func setAutomaticHiding(_ enabled: Bool) {
        behavior.setAutomaticHiding(enabled, pointer: NSEvent.mouseLocation)
        synchronize()
    }

    func recover() {
        panel?.cancelGeometryInteraction()
        behavior.recover()
        synchronize()
    }

    func findWindow() {
        recover()
        panel?.revealTransparencySettings()
    }

    func hide() {
        behavior.hide()
        synchronize()
    }

    func close() {
        stopSampling()
        behavior.close()
        panel?.dispose()
        panel = nil
        needsTransparencyRecovery = false
        synchronize()
    }

    func quit() {
        close()
        NSApplication.shared.terminate(nil)
    }

    private func synchronize() {
        let current = behavior.snapshot
        if snapshot != current {
            if let current { panel?.apply(current) }
            snapshot = current
        }
        guard let current, current.automaticHiding else {
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
        guard sampledWindowID == id, let panel, !panel.keepsWindowVisible else { return }
        behavior.samplePointer(NSEvent.mouseLocation, for: id, editing: panel.hasEditingFocus)
        synchronize()
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
