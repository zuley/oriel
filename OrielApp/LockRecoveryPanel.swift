import AppKit

@MainActor
final class LockRecoveryPanel: NSPanel {
    let button: ChromeButton

    init(unlock: @escaping () -> Void) {
        button = MiniWindowChromeView.makeLockRecoveryControl(unlock: unlock)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "取消穿透"
        animationBehavior = .none
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [.stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .aqua)
        contentView = button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
