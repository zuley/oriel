import AppKit

/// Draws a page kind's icon as an image so tabs and tiles share one look.
@MainActor
enum PageIcon {
    static func image(_ kind: PageKind, size: CGFloat = 14, color: NSColor = ChromePalette.ink) -> NSImage {
        if let name = kind.symbolName,
           let base = NSImage(systemSymbolName: name, accessibilityDescription: kind.title) {
            let configuration = NSImage.SymbolConfiguration(pointSize: size - 1, weight: .regular)
                .applying(.init(paletteColors: [color]))
            let image = base.withSymbolConfiguration(configuration) ?? base
            image.isTemplate = false
            return image
        }
        return drawn(size: size) { rect in ChromeSymbol.stocks.draw(in: rect, color: color) }
    }

    private static func drawn(size: CGFloat, _ draw: (NSRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(size * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: NSSize(width: size, height: size)) }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let flip = NSAffineTransform()
        flip.scaleX(by: scale, yBy: -scale)
        flip.translateX(by: 0, yBy: -size)
        flip.concat()
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}

/// The new-tab screen: a launcher for every page kind.
@MainActor
final class ChromeHomeView: NSView {
    var onOpenPage: ((PageKind) -> Void)?
    var onDropNovel: (([URL]) -> Bool)?

    private static let tileHeight: CGFloat = 72
    private static let tileGap: CGFloat = 6
    private static let margin: CGFloat = 12

    private var tiles: [(kind: PageKind, button: HomeTileButton)] = []
    private let welcome = ChromeHomeView.welcomeLabel()
    private var backgroundOpacity: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for kind in PageKind.allCases {
            let button = HomeTileButton(kind: kind)
            button.target = self
            button.action = #selector(tilePressed(_:))
            addSubview(button)
            tiles.append((kind, button))
        }
        addSubview(welcome)
        registerForDraggedTypes([.fileURL])
        setActionsEnabled(true)
    }

    required init?(coder: NSCoder) { nil }

    private static func welcomeLabel() -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        let font = NSFont(name: "STSongti-SC-Regular", size: 22)
            ?? .systemFont(ofSize: 22)
        let text = NSAttributedString(string: "每有会意，\n便欣然忘食。", attributes: [
            .font: font, .foregroundColor: ChromePalette.ink, .paragraphStyle: paragraph
        ])
        return NSTextField(labelWithAttributedString: text)
    }

    func setBackgroundOpacity(_ background: CGFloat) {
        backgroundOpacity = background
        for tile in tiles { tile.button.restingFill = background }
        needsDisplay = true
    }

    func setActionsEnabled(_ enabled: Bool) {
        for tile in tiles {
            tile.button.isEnabled = enabled
            tile.button.toolTip = enabled ? "打开" + tile.kind.title : nil
        }
    }

    @objc private func tilePressed(_ sender: HomeTileButton) { onOpenPage?(sender.kind) }

    // MARK: Drag a book onto the novel tile

    private var novelTile: HomeTileButton? { tiles.first { $0.kind == .novel }?.button }

    private func incomingBooks(_ sender: NSDraggingInfo) -> [URL]? {
        guard novelTile?.isEnabled == true,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.allSatisfy({ ["epub", "txt"].contains($0.pathExtension.lowercased()) }) else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard incomingBooks(sender) != nil else { return [] }
        novelTile?.setDropHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { novelTile?.setDropHighlight(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { novelTile?.setDropHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        novelTile?.setDropHighlight(false)
        guard let urls = incomingBooks(sender) else { return false }
        return onDropNovel?(urls) == true
    }

    // MARK: Layout

    private var isCompact: Bool { bounds.width < 216 || bounds.height < 190 }

    override func layout() {
        super.layout()
        if isCompact {
            layoutCompact()
        } else {
            layoutLauncher()
        }
    }

    /// One centered row of icons, for the smallest windows.
    private func layoutCompact() {
        welcome.isHidden = true
        let count = CGFloat(tiles.count)
        let side = min(40, bounds.height, max(0, bounds.width - 6) / count)
        let total = count * side + 2 * (count - 1)
        for (index, tile) in tiles.enumerated() {
            tile.button.compact = true
            tile.button.frame = NSRect(x: bounds.midX - total / 2 + CGFloat(index) * (side + 2),
                                       y: bounds.midY - side / 2, width: side, height: side)
        }
    }

    /// Center the welcome text and launcher grid as one block.
    private func layoutLauncher() {
        let margin = Self.margin
        let columns = 3
        let rowCount = Int((CGFloat(tiles.count) / CGFloat(columns)).rounded(.up))
        let tileWidth = min(76, (bounds.width - 2 * margin - CGFloat(columns - 1) * Self.tileGap) / CGFloat(columns))
        let gridHeight = CGFloat(rowCount) * Self.tileHeight + CGFloat(rowCount - 1) * Self.tileGap
        let welcomeHeight = ceil(welcome.intrinsicContentSize.height)
        let welcomeGap: CGFloat = 14
        let available = bounds.height - 2 * margin

        let showWelcome = gridHeight + welcomeHeight + welcomeGap <= available
        let total = gridHeight + (showWelcome ? welcomeHeight + welcomeGap : 0)
        var y = max(margin, (bounds.height - total) / 2)

        welcome.isHidden = !showWelcome
        if showWelcome {
            welcome.frame = NSRect(x: margin, y: y, width: bounds.width - 2 * margin, height: welcomeHeight)
            y += welcomeHeight + welcomeGap
        }
        // A partial last row is centered on its own, not left-aligned in a full-width grid.
        for row in 0..<rowCount {
            let first = row * columns
            let count = min(columns, tiles.count - first)
            let rowWidth = CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.tileGap
            let rowX = (bounds.width - rowWidth) / 2
            for column in 0..<count {
                let button = tiles[first + column].button
                button.compact = false
                button.frame = NSRect(x: rowX + CGFloat(column) * (tileWidth + Self.tileGap),
                                      y: y + CGFloat(row) * (Self.tileHeight + Self.tileGap),
                                      width: tileWidth, height: Self.tileHeight)
            }
        }
    }
}

/// A launcher tile: icon above its name, or the icon alone in small windows.
@MainActor
private final class HomeTileButton: NSButton {
    private static let restingColor = OrielPalette.field.blended(withFraction: 0.25, of: OrielPalette.sidebar)
        ?? OrielPalette.field
    let kind: PageKind
    var compact = false { didSet { needsDisplay = true } }
    /// A quiet gray tile follows the window's background opacity, as the toolbar does.
    var restingFill: CGFloat = 1 { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var dropTarget = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
            if !isEnabled { hovered = false }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(kind: PageKind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        title = kind.title
        font = .systemFont(ofSize: 12)
        setAccessibilityLabel(kind.title)
        focusRingType = .exterior
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { nil }

    func setDropHighlight(_ value: Bool) { dropTarget = value }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // Mini windows are nonactivating panels, so also handle tracking-area cursor
    // updates while the window is not key, like the native resize handles do.
    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8) }

    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        Self.restingColor.withAlphaComponent(restingFill).setFill()
        shape.fill()
        if isEnabled && (hovered || isHighlighted || dropTarget) {
            (dropTarget ? OrielPalette.selection
                : (isHighlighted ? ChromePalette.pressed : ChromePalette.hover)).setFill()
            shape.fill()
        }
        let tint = isEnabled ? ChromePalette.ink : ChromePalette.disabled
        let iconSize: CGFloat = compact ? 18 : 20
        let icon = PageIcon.image(kind, size: iconSize, color: tint)
        let iconY = compact ? bounds.midY - iconSize / 2 : bounds.midY - 20
        icon.draw(in: NSRect(x: bounds.midX - iconSize / 2, y: iconY, width: iconSize, height: iconSize),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard !compact else { return }
        let label = NSAttributedString(string: kind.title, attributes: [
            .font: font ?? .systemFont(ofSize: 12), .foregroundColor: tint
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY + 13 - size.height / 2))
    }
}
