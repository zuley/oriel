import AppKit

/// A small anchored panel gives the compact settings a controlled corner radius.
@MainActor
final class WindowSettingsPanel: NSPanel {
    var onDismiss: (() -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 224, height: 72),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "透明度设置"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSView) {
        guard let owner = anchor.window, let content = contentViewController?.view else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = OrielPalette.surface.cgColor
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        let anchorFrame = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = content.frame.size
        let screen = owner.screen?.visibleFrame ?? owner.frame
        let x = min(max(anchorFrame.maxX - size.width, screen.minX + 4), screen.maxX - size.width - 4)
        var y = anchorFrame.minY - size.height - 4
        if y < screen.minY + 4 { y = anchorFrame.maxY + 4 }
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        owner.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)

        // Keep slider drags inside the panel; close on clicks elsewhere or Escape.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak anchor] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.performClose(nil)
                    return nil
                }
            } else if event.window !== self {
                // Let the anchor button toggle this panel itself.
                if let anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.performClose(nil)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.performClose(nil)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
    }

    override func performClose(_ sender: Any?) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        onDismiss?()
        onDismiss = nil
    }
}

@MainActor
final class OpacitySliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let y = rect.midY
        let knob = knobRect(flipped: flipped)
        let track = rect.insetBy(dx: knob.width / 2, dy: 0)
        let thumbX = min(max(knob.midX, track.minX), track.maxX)
        let accent = OrielPalette.accent
        let gray = OrielPalette.border
        gray.setFill()
        NSRect(x: track.minX, y: y - 1.5, width: track.width, height: 3).fill()
        accent.setFill()
        NSRect(x: track.minX, y: y - 1.5, width: thumbX - track.minX, height: 3).fill()
        for tick in 0...4 {
            let x = track.minX + CGFloat(tick) * track.width / 4
            (x <= thumbX ? accent : gray).setFill()
            NSRect(x: x - 0.5, y: y - 3, width: 1, height: 6).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let thumb = NSRect(x: knobRect.midX - 3.5, y: knobRect.midY - 8, width: 7, height: 16)
        let path = NSBezierPath(roundedRect: thumb, xRadius: 3.5, yRadius: 3.5)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        OrielPalette.border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

@MainActor
final class WindowSettingsController: NSViewController {
    private let backgroundSlider: NSSlider
    private let contentSlider: NSSlider
    private let changed: (Double, Double) -> Void

    init(background: Double, content: Double, changed: @escaping (Double, Double) -> Void) {
        backgroundSlider = Self.makeSlider(value: background)
        contentSlider = Self.makeSlider(value: content)
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func makeSlider(value: Double) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.cell = OpacitySliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.altIncrementValue = 0.1
        slider.doubleValue = value
        return slider
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 72))
        view.appearance = NSAppearance(named: .aqua)
        let rows: [(String, NSSlider, CGFloat)] = [
            ("内容透明度", contentSlider, 44),
            ("背景透明度", backgroundSlider, 12)
        ]
        for (title, slider, y) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = OrielPalette.ink
            label.frame = NSRect(x: 12, y: y, width: 66, height: 17)
            slider.frame = NSRect(x: 83, y: y - 3, width: 132, height: 23)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged)
            slider.setAccessibilityLabel(title)
            slider.setAccessibilityHelp("向左变透明，向右变清晰")
            view.addSubview(label)
            view.addSubview(slider)
        }
    }

    @objc private func sliderChanged() {
        changed(backgroundSlider.doubleValue, contentSlider.doubleValue)
    }
}
