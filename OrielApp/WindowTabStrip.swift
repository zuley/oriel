import AppKit

/// The row of tabs under the toolbar. Each tab uses a short text title;
/// the selected one uses a solid accent fill, without borders or underlines.
@MainActor
final class WindowTabStrip: NSView {
    private static let spacing: CGFloat = 2
    private static let overflowWidth: CGFloat = 26
    private static let addWidth: CGFloat = 22

    private let selectTab: (Int) -> Void
    private let closeTab: (Int) -> Void
    private let addTab: () -> Void
    private let addButton = NSButton()
    private let overflow = NSButton()
    private var chips: [TabChip] = []
    private var selectedNumber = 0
    private var enabled = true
    var onOverflow: ((NSView) -> Void)?

    override var isFlipped: Bool { true }

    init(select: @escaping (Int) -> Void, close: @escaping (Int) -> Void,
         add: @escaping () -> Void) {
        selectTab = select
        closeTab = close
        addTab = add
        super.init(frame: .zero)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建页签")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.contentTintColor = ChromePalette.secondary
        addButton.toolTip = "新建页签"
        addButton.setAccessibilityLabel("新建页签")
        addButton.target = self
        addButton.action = #selector(addPressed)
        addSubview(addButton)
        overflow.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "全部页签")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        overflow.imagePosition = .imageOnly
        overflow.isBordered = false
        overflow.contentTintColor = ChromePalette.ink
        overflow.toolTip = "全部页签"
        overflow.setAccessibilityLabel("全部页签")
        overflow.target = self
        overflow.action = #selector(overflowPressed)
        overflow.isHidden = true
        addSubview(overflow)
    }

    required init?(coder: NSCoder) { nil }

    func select(_ number: Int) { selectTab(number) }

    func setTabs(_ tabs: [ChromeTab], selected: Int) {
        selectedNumber = selected
        for chip in chips { chip.removeFromSuperview() }
        chips = tabs.map { tab in
            let chip = TabChip(tab: tab, selected: tab.number == selected, select: selectTab, close: closeTab)
            addSubview(chip, positioned: .below, relativeTo: overflow)
            return chip
        }
        setEnabled(enabled)
        needsLayout = true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        addButton.isEnabled = enabled
        overflow.isEnabled = enabled
        for chip in chips { chip.setEnabled(enabled) }
    }

    override func layout() {
        super.layout()
        guard let selected = chips.firstIndex(where: { $0.number == selectedNumber }) else {
            addButton.isHidden = true
            overflow.isHidden = true
            return
        }
        addButton.isHidden = false
        let spacing = Self.spacing
        let widths = chips.map(\.preferredWidth)
        let total = widths.reduce(0, +) + spacing * CGFloat(chips.count - 1)
        let tabSpace = max(0, bounds.width - Self.addWidth - spacing)
        var visible = Set(chips.indices)
        var selectedWidth = widths[selected]
        if total > tabSpace {
            // Keep the selected tab and as many neighbours as fit; the rest are in the menu.
            let available = max(0, tabSpace - Self.overflowWidth - spacing)
            selectedWidth = min(widths[selected], max(0, available))
            visible = [selected]
            var remaining = available - selectedWidth
            let nearest = chips.indices.sorted {
                let lhs = abs($0 - selected), rhs = abs($1 - selected)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            for index in nearest where index != selected && widths[index] + spacing <= remaining {
                visible.insert(index)
                remaining -= widths[index] + spacing
            }
        }
        var x: CGFloat = 0
        for (index, chip) in chips.enumerated() {
            chip.isHidden = !visible.contains(index)
            guard !chip.isHidden else { continue }
            let width = index == selected ? selectedWidth : widths[index]
            chip.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + spacing
        }
        overflow.isHidden = visible.count == chips.count
        overflow.frame = NSRect(x: bounds.width - Self.overflowWidth, y: 0,
                                width: Self.overflowWidth, height: bounds.height - 1)
        let addLimit = (overflow.isHidden ? bounds.width : overflow.frame.minX - spacing) - Self.addWidth
        addButton.frame = NSRect(x: min(x, addLimit), y: 0,
                                 width: Self.addWidth, height: bounds.height - 1)
    }

    @objc private func addPressed() { addTab() }
    @objc private func overflowPressed() { onOverflow?(overflow) }
}

@MainActor
private final class TabChip: NSView {
    let number: Int
    private let tab: ChromeTab
    private let selected: Bool
    private let titleButton = NSButton()
    private let closeButton = NSButton()
    private let selectTab: (Int) -> Void
    private let closeTab: (Int) -> Void
    private var enabled = true
    private var hovered = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private static let closeWidth: CGFloat = 18
    private static let titleLeadingInset: CGFloat = 8

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat {
        let text = NSAttributedString(string: tab.title, attributes: [.font: font])
        return min(140, max(64, ceil(text.size().width) + 6 + Self.closeWidth + Self.titleLeadingInset))
    }

    private var font: NSFont { .systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular) }

    init(tab: ChromeTab, selected: Bool, select: @escaping (Int) -> Void, close: @escaping (Int) -> Void) {
        number = tab.number
        self.tab = tab
        self.selected = selected
        selectTab = select
        closeTab = close
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        titleButton.title = tab.title
        titleButton.font = font
        titleButton.alignment = .left
        titleButton.imagePosition = .noImage
        titleButton.contentTintColor = selected ? .white : ChromePalette.secondary
        titleButton.cell?.lineBreakMode = .byTruncatingTail
        titleButton.setAccessibilityValue(selected)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = selected ? .white : ChromePalette.secondary
        closeButton.toolTip = "关闭" + tab.title
        closeButton.setAccessibilityLabel("关闭" + tab.title)
        closeButton.isHidden = true
        for button in [titleButton, closeButton] {
            button.isBordered = false
            button.target = self
            addSubview(button)
        }
        titleButton.action = #selector(selectPressed)
        closeButton.action = #selector(closePressed)
    }

    required init?(coder: NSCoder) { nil }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        titleButton.isEnabled = enabled
        closeButton.isEnabled = enabled
        refresh()
    }

    private func refresh() {
        closeButton.isHidden = !(hovered && enabled)
        let tint: NSColor = enabled ? (selected ? .white : ChromePalette.secondary) : ChromePalette.disabled
        titleButton.contentTintColor = tint
        closeButton.contentTintColor = tint
        let fill = selected
            ? (enabled ? OrielPalette.accent : ChromePalette.divider)
            : (hovered && enabled ? ChromePalette.hover : OrielPalette.field)
        layer?.backgroundColor = fill.cgColor
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        guard let window else { hovered = false; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovered = !isHiddenOrHasHiddenAncestor && visibleRect.contains(point)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func layout() {
        super.layout()
        titleButton.frame = NSRect(x: Self.titleLeadingInset, y: 0,
                                   width: max(0, bounds.width - Self.closeWidth - Self.titleLeadingInset), height: bounds.height)
        closeButton.frame = NSRect(x: bounds.width - Self.closeWidth, y: 0, width: Self.closeWidth, height: bounds.height)
    }

    @objc private func selectPressed() { selectTab(number) }
    @objc private func closePressed() { closeTab(number) }
}

/// In short windows the toolbar title becomes this: the current tab, with a menu of all of them.
@MainActor
final class TabSwitcherButton: NSButton {
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        setAccessibilityLabel("切换页签")
        toolTip = "切换页签"
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ tab: ChromeTab?) {
        title = tab?.title ?? ""
        setAccessibilityValue(title)
        needsDisplay = true
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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isEnabled && (hovered || isHighlighted)
            ? (isHighlighted ? ChromePalette.pressed : ChromePalette.hover) : OrielPalette.field
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        let tint = isEnabled ? ChromePalette.ink : ChromePalette.disabled
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: tint, .paragraphStyle: paragraph])
        let chevronWidth: CGFloat = 12
        let textWidth = min(ceil(text.size().width), max(0, bounds.width - chevronWidth - 16))
        let total = textWidth + chevronWidth
        var x = max(8, (bounds.width - total) / 2)
        let height = text.size().height
        text.draw(in: NSRect(x: x, y: bounds.midY - height / 2, width: textWidth, height: height))
        x += textWidth + 3
        let chevron = NSBezierPath()
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.move(to: NSPoint(x: x + 1, y: bounds.midY - 1.5))
        chevron.line(to: NSPoint(x: x + 4.5, y: bounds.midY + 1.5))
        chevron.line(to: NSPoint(x: x + 8, y: bounds.midY - 1.5))
        tint.setStroke()
        chevron.stroke()
    }
}
