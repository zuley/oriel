import AppKit
import Combine
import OrielCore
import OrielTerminal

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: WindowSnapshot?
    private let behavior = WindowBehaviorController()
    private var panel: MiniPanel?
    private var sampler: Timer?
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

    func hide() {
        behavior.hide()
        synchronize()
    }

    func close() {
        stopSampling()
        behavior.close()
        panel?.dispose()
        panel = nil
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
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            // Scheduled exclusively on the main run loop; all state and AppKit access stay here.
            MainActor.assumeIsolated {
                guard let self, self.panel?.keepsWindowVisible != true else { return }
                self.behavior.samplePointer(NSEvent.mouseLocation, for: id)
                self.synchronize()
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func stopSampling() {
        sampler?.invalidate()
        sampler = nil
        sampledWindowID = nil
    }
}
