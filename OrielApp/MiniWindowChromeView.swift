import AppKit
import WebKit

@MainActor
final class MiniWindowChromeView: NSView {
    struct Actions {
        var addTab: () -> Void
        var selectTab: (Int) -> Void
        var closeTab: (Int) -> Void
        var openTerminal: () -> Void = {}
        var openStocks: () -> Void = {}
        var toggleAutomaticHiding: () -> Void
        var settings: (NSView) -> Void
        var toggleLock: () -> Void
        var hide: () -> Void
        var close: () -> Void
        var drag: (NSEvent) -> Void
    }

    private let content = ChromeContentView()
    private let home = ChromeHomeView(frame: .zero)
    private let webHost = ChromeClippingView(frame: .zero)
    private let surfaceHost = NSView()
    private let tabBar: WindowTabBar
    private let dragAction: (NSEvent) -> Void
    private let automaticHidingButton: ChromeButton
    let settingsButton: ChromeButton
    private let lockButton: ChromeButton
    private var toolbarButtons: [ChromeButton] = []
    private var isLocked = false
    private let hoverTip = ChromeTooltipView(frame: .zero)
    private var hoverTimer: Timer?
    private weak var hoveredButton: ChromeButton?

    override var isFlipped: Bool { true }
    var usesCompactToolbar: Bool { (window?.frame.width ?? bounds.width) < 280 }

    init(actions: Actions) {
        tabBar = WindowTabBar(select: actions.selectTab, close: actions.closeTab)
        dragAction = actions.drag
        let addTab = ChromeButton(symbol: .add, label: "新建页签") { _ in actions.addTab() }
        automaticHidingButton = ChromeButton(symbol: .eye, label: "开启边缘唤醒") { _ in
            actions.toggleAutomaticHiding()
        }
        lockButton = ChromeButton(symbol: .lock, label: "锁定穿透") { _ in actions.toggleLock() }
        settingsButton = ChromeButton(symbol: .settings, label: "设置", action: actions.settings)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 360))

        home.onOpenTerminal = actions.openTerminal
        home.onOpenStocks = actions.openStocks
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = ChromePalette.background.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]

        let hide = ChromeButton(symbol: .minus, label: "收起到菜单栏") { _ in actions.hide() }
        let close = ChromeButton(symbol: .close, label: "关闭小窗") { _ in actions.close() }
        toolbarButtons = [addTab, automaticHidingButton, settingsButton, lockButton, hide, close]
        for button in toolbarButtons {
            button.onHover = { [weak self, weak button] entered in
                guard let self, let button else { return }
                if entered { self.scheduleTooltip(for: button) }
                else if self.hoveredButton === button { self.dismissTooltip() }
            }
            addSubview(button)
        }

        addSubview(content)
        content.addSubview(home)
        content.addSubview(webHost)
        surfaceHost.wantsLayer = true
        addSubview(surfaceHost)
        tabBar.isHidden = true
        addSubview(tabBar)
        hoverTip.isHidden = true
        addSubview(hoverTip)
        showHome()
        update(isLocked: false, automaticHiding: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dismissTooltip()
        let narrow = bounds.width < 168
        let centers: [CGFloat?] = [
            narrow ? 40 : 60, usesCompactToolbar ? nil : bounds.width - 74,
            bounds.width - (narrow ? 42 : 46), Self.lockControlFrame(for: bounds.width).midX,
            narrow ? 24 : 34, narrow ? 8 : 16
        ]
        for (button, center) in zip(toolbarButtons, centers) {
            button.isHidden = center == nil || (isLocked && button === lockButton)
            if let center {
                let width: CGFloat = button.isWindowControl ? (narrow ? 16 : 18) : (narrow && button !== lockButton ? 16 : 28)
                button.frame = NSRect(x: center - width / 2, y: 0, width: width, height: 28)
            }
        }
        tabBar.frame = NSRect(x: 6, y: 28, width: max(0, bounds.width - 12),
                              height: tabBar.isHidden ? 0 : 24)
        let contentTop = tabBar.frame.maxY + 4
        content.frame = NSRect(x: 6, y: contentTop, width: max(0, bounds.width - 12),
                               height: max(0, bounds.height - contentTop - 6))
        home.frame = content.bounds
        webHost.frame = content.bounds.insetBy(dx: 1, dy: 1)
        surfaceHost.frame = NSRect(x: 0, y: contentTop, width: bounds.width,
                                    height: max(0, bounds.height - contentTop))
        content.needsDisplay = true
        home.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dismissTooltip()
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 6, point.y < 28,
              point.x >= 6, point.x < bounds.width - 6 else {
            super.mouseDown(with: event)
            return
        }
        // Buttons handle their own clicks. Only the otherwise empty toolbar reaches here.
        dragAction(event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        var start: CGFloat = 6
        for button in toolbarButtons.filter({ !$0.isHidden }).sorted(by: { $0.frame.minX < $1.frame.minX }) {
            if button.frame.minX > start {
                addCursorRect(NSRect(x: start, y: 6, width: button.frame.minX - start, height: 22),
                              cursor: .openHand)
            }
            start = button.frame.maxX
        }
    }

    func showHome() {
        surfaceHost.isHidden = true
        content.isHidden = false
        home.isHidden = false
        webHost.isHidden = true
    }

    func setTabs(_ tabs: [(Int, String)], selected: Int) {
        tabBar.isHidden = tabs.count < 2
        tabBar.setTabs(tabs, selected: selected)
        needsLayout = true
    }

    func showWebContent(_ webView: WKWebView) {
        if webView.superview !== webHost { webHost.subviews = [webView] }
        webView.frame = webHost.bounds
        webView.autoresizingMask = [.width, .height]
        surfaceHost.isHidden = true
        content.isHidden = false
        home.isHidden = true
        webHost.isHidden = false
    }

    func showTerminal(_ terminal: NSView) {
        showSurface(terminal, inset: 4, background: .black)
    }

    func showStocks(_ view: NSView) {
        showSurface(view, inset: 0, background: .clear)
    }

    private func showSurface(_ view: NSView, inset: CGFloat, background: NSColor) {
        content.isHidden = true
        surfaceHost.layer?.backgroundColor = background.cgColor
        surfaceHost.isHidden = false
        layoutSubtreeIfNeeded()
        view.frame = surfaceHost.bounds.insetBy(dx: inset, dy: inset)
        view.autoresizingMask = [.width, .height]
        if view.superview !== surfaceHost { surfaceHost.subviews = [view] }
    }

    func setContentOpacity(background: CGFloat, content: CGFloat, revealToolbar: Bool = false) {
        tabBar.alphaValue = background
        layer?.backgroundColor = ChromePalette.background.withAlphaComponent(background).cgColor
        for button in toolbarButtons {
            button.restingOpacity = revealToolbar ? 1 : background
        }
        self.content.alphaValue = content
        surfaceHost.alphaValue = content
        home.setBackgroundOpacity(background)
    }

    func update(isLocked: Bool, automaticHiding: Bool) {
        if self.isLocked != isLocked {
            dismissTooltip()
            self.isLocked = isLocked
            tabBar.setEnabled(!isLocked)
            home.setActionsEnabled(!isLocked)
            // The recovery child draws the lock while locked; never composite two copies.
            lockButton.isHidden = isLocked
            needsLayout = true
        }
        for button in toolbarButtons { button.isEnabled = !isLocked }
        automaticHidingButton.setActive(automaticHiding,
                                       label: automaticHiding ? "关闭边缘唤醒" : "开启边缘唤醒")
        lockButton.setActive(isLocked, label: isLocked ? "解除锁定穿透" : "锁定穿透")
    }

    static func lockControlFrame(for width: CGFloat) -> NSRect {
        let center = width - 18
        return NSRect(x: center - 14, y: 0, width: 28, height: 28)
    }

    static func makeLockRecoveryControl(unlock: @escaping () -> Void) -> ChromeButton {
        let button = ChromeButton(symbol: .lock, label: "取消穿透") { _ in unlock() }
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.setActive(true, label: "取消穿透")
        button.toolTip = "取消穿透"
        return button
    }

    func dismissTooltip() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoveredButton = nil
        hoverTip.isHidden = true
    }

    private func scheduleTooltip(for button: ChromeButton) {
        dismissTooltip()
        guard button.isEnabled else { return }
        hoveredButton = button
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button, button.isEnabled, self.hoveredButton === button,
                      !button.isHidden, self.window?.isVisible == true else { return }
                self.hoverTimer = nil
                let size = self.hoverTip.configure(button.hintText)
                let inset = min(8, max(0, (self.bounds.width - size.width) / 2))
                let x = min(max(inset, button.frame.midX - size.width / 2), self.bounds.width - size.width - inset)
                self.hoverTip.frame = NSRect(x: x, y: 30, width: size.width, height: size.height)
                self.hoverTip.isHidden = false
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
private final class WindowTabBar: NSView {
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let select: (Int) -> Void
    private let close: (Int) -> Void
    private var chips: [TabChip] = []
    private var selectedNumber = 0
    private var enabled = true

    init(select: @escaping (Int) -> Void, close: @escaping (Int) -> Void) {
        self.select = select
        self.close = close
        super.init(frame: .zero)
        picker.controlSize = .small
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 11)
        picker.setAccessibilityLabel("选择页签")
        picker.target = self
        picker.action = #selector(selectMenuItem)
    }

    required init?(coder: NSCoder) { nil }

    func setTabs(_ tabs: [(Int, String)], selected: Int) {
        selectedNumber = selected
        for chip in chips { chip.removeFromSuperview() }
        picker.removeFromSuperview()
        picker.removeAllItems()
        chips = tabs.map { number, title in
            let chip = TabChip(number: number, title: title, selected: number == selected,
                               select: select, close: close)
            addSubview(chip)
            picker.addItem(withTitle: title)
            picker.lastItem?.tag = number
            return chip
        }
        picker.selectItem(withTag: selected)
        addSubview(picker)
        setEnabled(enabled)
        needsLayout = true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        picker.isEnabled = enabled
        for chip in chips { chip.setEnabled(enabled) }
    }

    override func layout() {
        super.layout()
        let total = chips.reduce(CGFloat(0)) { $0 + $1.preferredWidth + 3 } - 3
        let overflow = total > bounds.width
        picker.isHidden = !overflow
        var x: CGFloat = 0
        for chip in chips {
            chip.isHidden = overflow && chip.number != selectedNumber
            guard !chip.isHidden else { continue }
            let width = overflow ? min(bounds.width, max(chip.preferredWidth + 18, 100)) : chip.preferredWidth
            chip.frame = NSRect(x: x, y: 1, width: width, height: 22)
            chip.titleButton.isHidden = overflow
            if overflow {
                picker.frame = NSRect(x: x, y: 1, width: width - TabChip.closeWidth, height: 22)
            }
            x += width + 3
        }
    }

    @objc private func selectMenuItem() {
        if let item = picker.selectedItem { select(item.tag) }
    }
}

@MainActor
private final class TabChip: NSView {
    static let closeWidth: CGFloat = 21
    let number: Int
    let titleButton = NSButton()
    private let closeButton = NSButton()
    private var pointerInside = false {
        didSet { updateCloseVisibility() }
    }
    private let select: (Int) -> Void
    private let close: (Int) -> Void
    private let selected: Bool
    var preferredWidth: CGFloat { ceil(titleButton.intrinsicContentSize.width) + Self.closeWidth + 10 }

    init(number: Int, title: String, selected: Bool,
         select: @escaping (Int) -> Void, close: @escaping (Int) -> Void) {
        self.number = number
        self.selected = selected
        self.select = select
        self.close = close
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleButton.title = title
        titleButton.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        titleButton.setAccessibilityValue(selected)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "关闭" + title
        closeButton.setAccessibilityLabel("关闭" + title)
        closeButton.isHidden = true
        for button in [titleButton, closeButton] {
            button.isBordered = false
            button.target = self
            addSubview(button)
        }
        titleButton.action = #selector(selectPressed)
        closeButton.action = #selector(closePressed)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    func setEnabled(_ enabled: Bool) {
        titleButton.isEnabled = enabled
        closeButton.isEnabled = enabled
        updateCloseVisibility()
        layer?.backgroundColor = (selected && enabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.055)).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard let window else {
            pointerInside = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        pointerInside = !isHiddenOrHasHiddenAncestor && visibleRect.contains(point)
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

    private func updateCloseVisibility() {
        closeButton.isHidden = !pointerInside || !closeButton.isEnabled
    }

    override func layout() {
        super.layout()
        titleButton.frame = NSRect(x: 0, y: 0, width: bounds.width - Self.closeWidth, height: bounds.height)
        closeButton.frame = NSRect(x: titleButton.frame.maxX, y: 0,
                                   width: Self.closeWidth, height: bounds.height)
    }

    @objc private func selectPressed() { select(number) }
    @objc private func closePressed() { close(number) }
}

@MainActor
private final class ChromeTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.96).cgColor
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ text: String) -> NSSize {
        label.stringValue = text
        let width = ceil(label.intrinsicContentSize.width)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 8, y: 5, width: width, height: height)
        return NSSize(width: width + 16, height: height + 10)
    }
}

@MainActor
private enum ChromePalette {
    static let background = NSColor(srgbRed: 254 / 255, green: 254 / 255, blue: 254 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 54 / 255, green: 54 / 255, blue: 54 / 255, alpha: 1)
    static let secondary = NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 154 / 255, alpha: 1)
    static let disabled = NSColor(srgbRed: 185 / 255, green: 185 / 255, blue: 185 / 255, alpha: 1)
    static let divider = NSColor(srgbRed: 233 / 255, green: 233 / 255, blue: 233 / 255, alpha: 1)
    static let hover = NSColor(srgbRed: 239 / 255, green: 239 / 255, blue: 239 / 255, alpha: 1)
    static let pressed = NSColor(srgbRed: 226 / 255, green: 226 / 255, blue: 226 / 255, alpha: 1)
}

@MainActor
private final class ChromeContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ChromeClippingView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ChromeHomeView: NSView {
    var onOpenTerminal: (() -> Void)?
    var onOpenStocks: (() -> Void)?
    private let stockButton = HomeTileButton(title: "自选股", target: nil, action: nil)
    private let terminalButton = HomeTileButton(title: "终端", target: nil, action: nil)
    private let heading: NSTextField
    private let subtitle: NSTextField
    private let novelLabel: NSTextField
    private var backgroundOpacity: CGFloat = 1

    override var isFlipped: Bool { true }
    private var isCompact: Bool { bounds.width < 240 || bounds.height < 264 }

    override init(frame frameRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        heading = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "让常用内容触手可及\n专注眼前，随时查看",
            attributes: [.font: NSFont(name: "PingFangSC-Semibold", size: 17)
                            ?? NSFont.systemFont(ofSize: 17, weight: .semibold),
                         .foregroundColor: ChromePalette.ink, .paragraphStyle: paragraph]
        ))
        heading.maximumNumberOfLines = 2
        heading.cell?.wraps = true
        subtitle = Self.label("或添加以下内容", size: 12)
        novelLabel = Self.label("小说", size: 11)
        super.init(frame: frameRect)
        terminalButton.isBordered = false
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        terminalButton.font = .systemFont(ofSize: 11)
        terminalButton.setAccessibilityLabel("终端")
        terminalButton.target = self
        terminalButton.action = #selector(openTerminal)
        addSubview(terminalButton)
        addSubview(heading)
        addSubview(subtitle)
        addSubview(novelLabel)
        stockButton.isBordered = false
        stockButton.font = terminalButton.font
        stockButton.symbol = .stocks
        stockButton.setAccessibilityLabel("自选股")
        stockButton.target = self
        stockButton.action = #selector(openStocks)
        addSubview(stockButton)
        setActionsEnabled(true)
    }

    func setActionsEnabled(_ enabled: Bool) {
        for button in [terminalButton, stockButton] {
            button.isEnabled = enabled
            button.toolTip = enabled ? "打开" + button.title : nil
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openStocks() { onOpenStocks?() }
    @objc private func openTerminal() { onOpenTerminal?() }

    func setBackgroundOpacity(_ background: CGFloat) {
        backgroundOpacity = background
        needsDisplay = true
    }

    private static func label(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        label.textColor = ChromePalette.secondary
        label.alignment = .center
        return label
    }

    override func layout() {
        super.layout()
        for label in [heading, subtitle, novelLabel] { label.isHidden = isCompact }
        let origin = NSPoint(x: (bounds.width - 240) / 2, y: (bounds.height - 240) / 2)
        let compactSide = min(40, bounds.height, (bounds.width - 4) / 2)
        terminalButton.imagePosition = isCompact ? .imageOnly : .imageAbove
        terminalButton.frame = isCompact
            ? NSRect(x: bounds.midX - compactSide - 2, y: bounds.midY - compactSide / 2, width: compactSide, height: compactSide)
            : NSRect(x: 20 + origin.x, y: 182 + origin.y, width: 56, height: 56)
        heading.frame = NSRect(x: origin.x, y: 80 + origin.y, width: 240, height: 48)
        subtitle.frame = NSRect(x: 66 + origin.x, y: 144 + origin.y, width: 108, height: 20)
        novelLabel.frame = NSRect(x: 92 + origin.x, y: 215 + origin.y, width: 56, height: 18)
        stockButton.imagePosition = terminalButton.imagePosition
        stockButton.frame = isCompact
            ? NSRect(x: bounds.midX + 2, y: terminalButton.frame.minY, width: compactSide, height: compactSide)
            : NSRect(x: 164 + origin.x, y: 182 + origin.y, width: 56, height: 56)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard !isCompact else { return }
        let origin = NSAffineTransform()
        origin.translateX(by: (bounds.width - 240) / 2, yBy: (bounds.height - 240) / 2)
        origin.concat()
        drawIllustration(center: NSPoint(x: 120, y: 30), scale: 0.75)

        ChromePalette.divider.setStroke()
        let divider = NSBezierPath()
        divider.lineWidth = 0.6
        divider.move(to: NSPoint(x: 16, y: 154))
        divider.line(to: NSPoint(x: 60, y: 154))
        divider.move(to: NSPoint(x: 180, y: 154))
        divider.line(to: NSPoint(x: 224, y: 154))
        divider.stroke()

        let symbols: [ChromeSymbol?] = [nil, .novel, nil]
        for (index, symbol) in symbols.enumerated() {
            let center = CGFloat(48 + index * 72)
            NSColor.white.withAlphaComponent(backgroundOpacity).setFill()
            NSBezierPath(roundedRect: NSRect(x: center - 28, y: 182, width: 56, height: 56),
                         xRadius: 4, yRadius: 4).fill()
            let symbolSize: CGFloat = index == 1 ? 20 : 18
            symbol?.draw(in: NSRect(x: center - symbolSize / 2, y: 200 - symbolSize / 2,
                                  width: symbolSize, height: symbolSize), color: ChromePalette.ink)
        }
    }

    private func drawIllustration(center: NSPoint, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.scale(by: scale)
        transform.translateX(by: -152, yBy: -115)
        transform.concat()
        ChromePalette.ink.setStroke()
        let window = NSBezierPath(roundedRect: NSRect(x: 124.9, y: 75.9, width: 54.2, height: 78.2),
                                  xRadius: 8, yRadius: 8)
        window.lineWidth = 1.8
        window.stroke()
        let illustration = NSBezierPath()
        illustration.lineWidth = 1.8
        illustration.lineCapStyle = .round
        illustration.move(to: NSPoint(x: 125, y: 91))
        illustration.line(to: NSPoint(x: 179, y: 91))
        illustration.move(to: NSPoint(x: 144, y: 123))
        illustration.line(to: NSPoint(x: 160, y: 123))
        illustration.move(to: NSPoint(x: 152, y: 115))
        illustration.line(to: NSPoint(x: 152, y: 131))
        illustration.stroke()
        ChromePalette.ink.setFill()
        for center in [CGFloat(159), 165, 171] {
            NSBezierPath(ovalIn: NSRect(x: center - 2, y: 82, width: 4, height: 4)).fill()
        }

    }

}

@MainActor
private final class HomeTileButton: NSButton {
    var symbol: ChromeSymbol?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let compact = imagePosition == .imageOnly
        let iconCenterY = compact ? bounds.midY : 18
        let icon = NSRect(x: bounds.midX - 9, y: iconCenterY - 9, width: 18, height: 18)
        if let symbol {
            symbol.draw(in: icon, color: ChromePalette.ink.withAlphaComponent(isHighlighted ? 0.6 : 1))
        } else {
            image?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.6 : 1,
                        respectFlipped: true, hints: nil)
        }
        guard !compact else { return }
        let label = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 11), .foregroundColor: ChromePalette.secondary
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 42 - size.height / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ChromeButton: NSButton {
    private let symbol: ChromeSymbol
    private let onPress: (NSView) -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false
    var restingOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }
    var iconOpacity: CGFloat { hovered && isEnabled ? 1 : restingOpacity }

    private var active = false
    var onHover: ((Bool) -> Void)?
    private(set) var hintText = ""
    var isWindowControl: Bool { symbol == .minus || symbol == .close }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    fileprivate init(symbol: ChromeSymbol, label: String, action: @escaping (NSView) -> Void) {
        self.symbol = symbol
        onPress = action
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(pressed)
        setHint(label)
        setAccessibilityLabel(label)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    func setActive(_ value: Bool, label: String) {
        if active != value {
            active = value
            needsDisplay = true
        }
        setAccessibilityValue(value)
        setAccessibilityLabel(label)
        setHint(label)
    }

    func setHint(_ text: String) {
        hintText = text
        setAccessibilityHelp(text)
    }

    @objc private func pressed() {
        onHover?(false)
        onPress(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHover?(false)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fade only the artwork so even an invisible icon keeps its tracking area.
        let opacity = iconOpacity
        guard opacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context.endTransparencyLayer()
            context.restoreGState()
        }
        let highlightedLock = isEnabled && active && symbol == .lock
        if symbol == .minus || symbol == .close {
            drawTrafficLight()
        } else {
            if isEnabled && (hovered || isHighlighted || active) {
                (highlightedLock ? NSColor.systemBlue.withAlphaComponent(0.14)
                    : (isHighlighted ? ChromePalette.pressed : ChromePalette.hover)).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 4, yRadius: 4).fill()
            }
            symbol.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14),
                        color: highlightedLock ? .systemBlue : (isEnabled ? ChromePalette.ink : ChromePalette.disabled))
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            focus.lineWidth = 1.5
            focus.stroke()
        }
    }

    private func drawTrafficLight() {
        let closing = symbol == .close
        let fill = isEnabled
            ? (closing ? NSColor(srgbRed: 1, green: 95 / 255, blue: 87 / 255, alpha: 1)
                       : NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1))
            : NSColor(white: 0.85, alpha: 1)
        let circle = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 5, y: bounds.midY - 5,
                                               width: 10, height: 10))
        (isEnabled && isHighlighted ? (fill.blended(withFraction: 0.15, of: .black) ?? fill) : fill).setFill()
        circle.fill()
        (fill.blended(withFraction: 0.18, of: .black) ?? fill).setStroke()
        circle.lineWidth = 0.7
        circle.stroke()
        if isEnabled && (hovered || isHighlighted) {
            let ink = closing ? NSColor(srgbRed: 0.48, green: 0.08, blue: 0.04, alpha: 1)
                              : NSColor(srgbRed: 0.55, green: 0.32, blue: 0.02, alpha: 1)
            symbol.draw(in: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7),
                        color: ink)
        }
    }
}

@MainActor
private enum ChromeSymbol: Equatable {
    case add, eye, settings, lock, minus, close, novel, stocks

    func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nativeTransform = NSAffineTransform()
        nativeTransform.translateX(by: rect.minX, yBy: rect.minY)
        nativeTransform.scaleX(by: rect.width / 20, yBy: rect.height / 20)
        nativeTransform.concat()
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func line(_ points: [NSPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
        }

        switch self {
        case .add:
            line([NSPoint(x: 3, y: 10), NSPoint(x: 17, y: 10)])
            line([NSPoint(x: 10, y: 3), NSPoint(x: 10, y: 17)])
        case .eye:
            path.move(to: NSPoint(x: 1, y: 10))
            path.curve(to: NSPoint(x: 19, y: 10), controlPoint1: NSPoint(x: 5, y: 2),
                       controlPoint2: NSPoint(x: 15, y: 2))
            path.curve(to: NSPoint(x: 1, y: 10), controlPoint1: NSPoint(x: 15, y: 18),
                       controlPoint2: NSPoint(x: 5, y: 18))
            path.appendOval(in: NSRect(x: 7, y: 7, width: 6, height: 6))
            NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 2, height: 2)).fill()
        case .settings:
            line([NSPoint(x: 2, y: 6), NSPoint(x: 10, y: 6)])
            line([NSPoint(x: 14, y: 6), NSPoint(x: 18, y: 6)])
            line([NSPoint(x: 2, y: 14), NSPoint(x: 5, y: 14)])
            line([NSPoint(x: 9, y: 14), NSPoint(x: 18, y: 14)])
            path.appendOval(in: NSRect(x: 10, y: 4, width: 4, height: 4))
            path.appendOval(in: NSRect(x: 5, y: 12, width: 4, height: 4))
        case .lock:
            path.appendRoundedRect(NSRect(x: 3.5, y: 8.5, width: 13, height: 10),
                                   xRadius: 2, yRadius: 2)
            path.move(to: NSPoint(x: 6, y: 8.5))
            path.line(to: NSPoint(x: 6, y: 6))
            path.curve(to: NSPoint(x: 14, y: 6), controlPoint1: NSPoint(x: 6, y: 0.5),
                       controlPoint2: NSPoint(x: 14, y: 0.5))
            path.line(to: NSPoint(x: 14, y: 8.5))
            line([NSPoint(x: 10, y: 12), NSPoint(x: 10, y: 15)])
        case .minus:
            line([NSPoint(x: 2, y: 10), NSPoint(x: 18, y: 10)])
        case .close:
            line([NSPoint(x: 4, y: 4), NSPoint(x: 16, y: 16)])
            line([NSPoint(x: 16, y: 4), NSPoint(x: 4, y: 16)])
        case .novel:
            path.move(to: NSPoint(x: 3, y: 12.5))
            path.line(to: NSPoint(x: 13.5, y: 2))
            path.line(to: NSPoint(x: 17.5, y: 15.5))
            path.line(to: NSPoint(x: 19, y: 17))
            path.line(to: NSPoint(x: 3, y: 17))
            path.curve(to: NSPoint(x: 3, y: 12.5), controlPoint1: NSPoint(x: 0, y: 17),
                       controlPoint2: NSPoint(x: 0.5, y: 14.5))
            path.appendOval(in: NSRect(x: 5.5, y: 11, width: 2, height: 2))
            line([NSPoint(x: 11, y: 9), NSPoint(x: 11.5, y: 7.5), NSPoint(x: 12.5, y: 9)])
            line([NSPoint(x: 12.5, y: 14), NSPoint(x: 13, y: 12.5), NSPoint(x: 14, y: 14)])
        case .stocks:
            path.appendRoundedRect(NSRect(x: 2, y: 1.5, width: 16, height: 17), xRadius: 4, yRadius: 4)
            line([NSPoint(x: 2.5, y: 6), NSPoint(x: 17.5, y: 6)])
            line([NSPoint(x: 4, y: 14), NSPoint(x: 7, y: 11.5), NSPoint(x: 10, y: 13),
                  NSPoint(x: 15, y: 8.5)])
            line([NSPoint(x: 11.5, y: 8.5), NSPoint(x: 15, y: 8.5), NSPoint(x: 15, y: 12)])
        }
        path.stroke()
    }
}
