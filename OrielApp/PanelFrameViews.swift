import AppKit

// Edge resize handles, their cursors and the drawn window shadow of a mini window.

struct PanelResizeEdge: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let top = Self(rawValue: 4)
    static let bottom = Self(rawValue: 8)

    @MainActor var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if isDisjoint(with: [.left, .right]) { return .resizeUpDown }
        if isDisjoint(with: [.top, .bottom]) { return .resizeLeftRight }
        let rising = self == [.bottom, .left] || self == [.top, .right]
        let source = NSCursor.resizeLeftRight.image
        let size = NSSize(width: 32, height: 32)
        let center = NSPoint(x: 16, y: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: rising ? 45 : -45)
            transform.concat()
            source.draw(in: NSRect(x: -source.size.width / 2, y: -source.size.height / 2,
                                   width: source.size.width, height: source.size.height))
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}

/// WindowServer otherwise ignores cursor changes from an inactive menu-bar app.
/// Resolve this optional connection property at runtime so normal AppKit cursor rects
/// still work on systems without it. Enable it only during a resize hover.
enum BackgroundResizeCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func allow(_ enabled: Bool) {
        let symbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionFunction = dlsym(symbols, "CGSMainConnectionID"),
              let propertyFunction = dlsym(symbols, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionFunction, to: MainConnection.self)()
        let setProperty = unsafeBitCast(propertyFunction, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                        enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

@MainActor
final class PanelResizeHandle: NSView {
    let edge: PanelResizeEdge
    private let resizeCursor: NSCursor

    init(_ edge: PanelResizeEdge) {
        self.edge = edge
        resizeCursor = edge.cursor
        super.init(frame: .zero)
        setAccessibilityElement(false)
        // Cursor rects are only active in a key window. This panel usually isn't key.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect,
            .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self, userInfo: nil))
    }

    private func showCursor() {
        guard let panel = window as? MiniPanel, panel.isVisible, !panel.ignoresMouseEvents else { return }
        let point = superview?.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        if let point, (superview as? PanelShadowView)?.hasControl(at: point) == true {
            releaseCursor()
            return
        }
        if panel.hoveredResizeHandle == nil { BackgroundResizeCursor.allow(true) }
        panel.hoveredResizeHandle = self
        resizeCursor.set()
    }

    func releaseCursor() {
        guard let panel = window as? MiniPanel, panel.hoveredResizeHandle === self else { return }
        panel.hoveredResizeHandle = nil
        NSCursor.arrow.set()
        BackgroundResizeCursor.allow(false)
    }

    override func mouseEntered(with event: NSEvent) { showCursor() }
    override func mouseMoved(with event: NSEvent) { showCursor() }
    override func mouseExited(with event: NSEvent) { releaseCursor() }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .scrollWheel, .rightMouseDown, .rightMouseUp: return nil
        default:
            guard let hit = super.hitTest(point),
                  (superview as? PanelShadowView)?.hasControl(at: point) != true else { return nil }
            return hit
        }
    }
    override func cursorUpdate(with event: NSEvent) { showCursor() }
    override func mouseDown(with event: NSEvent) { (window as? MiniPanel)?.startEdgeResize(event) }
    override func mouseDragged(with event: NSEvent) { (window as? MiniPanel)?.dragEdge(edge, event: event) }
    override func mouseUp(with event: NSEvent) { (window as? MiniPanel)?.endEdgeResize() }
}

@MainActor
final class PanelShadowView: NSView {
    weak var chrome: MiniWindowChromeView?
    var highlighted = false { didSet { needsDisplay = true } }

    func hasControl(at point: NSPoint) -> Bool {
        var view = chrome?.hitTest(point)
        while let candidate = view {
            if candidate is NSButton || candidate is NSScroller { return true }
            view = candidate.superview
        }
        return false
    }

    var bodyRect: NSRect { bounds.insetBy(dx: 4, dy: 4) }
    var shadowStrength: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private var handles: [PanelResizeHandle] = []

    func installResizeHandles() {
        let edges: [PanelResizeEdge] = [.left, .right, .top, .bottom,
                                        [.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right]]
        handles = edges.map(PanelResizeHandle.init)
        handles.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let corner: CGFloat = 20
        let band: CGFloat = 14
        let topBand: CGFloat = 12
        let toolbarBottom = bodyRect.maxY - 28
        for handle in handles {
            handle.isHidden = chrome?.isFolded == true
            if handle.isHidden { continue }
            let edge = handle.edge
            let left = edge.contains(.left), right = edge.contains(.right)
            let top = edge.contains(.top), bottom = edge.contains(.bottom)
            let isCorner = (left || right) && (top || bottom)
            let width = isCorner ? corner : (left || right ? band : bounds.width - 2 * corner)
            let x = left ? bounds.minX : (right ? bounds.maxX - width : bounds.minX + corner)
            let y: CGFloat
            let height: CGFloat
            if top {
                height = topBand
                y = bounds.maxY - height
            } else if bottom {
                height = isCorner ? corner : band
                y = bounds.minY
            } else {
                // Keep the sides of the toolbar free for the traffic lights and lock.
                y = bounds.minY + corner
                height = toolbarBottom - y
            }
            handle.frame = NSRect(x: x, y: y, width: width, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Sample the same four-point falloff along every edge and around each corner.
        let opacities: [CGFloat] = [0.125, 0.075, 0.03, 0.006]
        for (index, opacity) in opacities.enumerated() {
            let distance = CGFloat(index) + 0.5
            let rect = bodyRect.insetBy(dx: -distance, dy: -distance)
            let ring = NSBezierPath(roundedRect: rect, xRadius: 8 + distance, yRadius: 8 + distance)
            ring.lineWidth = 1
            NSColor.black.withAlphaComponent(opacity * shadowStrength).setStroke()
            ring.stroke()
        }
        if highlighted {
            let ring = NSBezierPath(roundedRect: bodyRect.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            OrielPalette.accent.setStroke()
            ring.stroke()
        }
    }
}
