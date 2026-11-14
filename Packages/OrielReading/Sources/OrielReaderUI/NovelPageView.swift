import SwiftUI
import OrielReading

public struct NovelPageView: NSViewRepresentable {
    let bookID: String
    let chapter: NovelChapter
    let index: Int
    let offset: Int
    let highlight: NSRange?
    let simplified: Bool
    let fontSize: CGFloat
    let onPosition: (Int) -> Void
    let onTurn: (Int) -> Void
    let onPreviousChapterEnd: (() -> Void)?

    public init(bookID: String, chapter: NovelChapter, index: Int, offset: Int, highlight: NSRange?,
                simplified: Bool, fontSize: CGFloat, onPosition: @escaping (Int) -> Void, onTurn: @escaping (Int) -> Void,
                onPreviousChapterEnd: (() -> Void)? = nil) {
        self.bookID = bookID
        self.chapter = chapter
        self.index = index
        self.offset = offset
        self.highlight = highlight
        self.simplified = simplified
        self.fontSize = fontSize
        self.onPosition = onPosition
        self.onTurn = onTurn
        self.onPreviousChapterEnd = onPreviousChapterEnd
    }

    public func makeNSView(context: Context) -> NovelPageScroll { NovelPageScroll() }
    public func updateNSView(_ view: NovelPageScroll, context: Context) {
        view.show(self)
    }
}

@MainActor
public final class NovelPageScroll: NSScrollView {
    private static let paragraphBreaks = try! NSRegularExpression(pattern: "(?<=\n)\n+")
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .init(width: 200, height: CGFloat.greatestFiniteMagnitude))
    private let reader: ReadingTextView
    private var bookID: String?
    private var chapterIndex = -1
    private var size: CGFloat = 0
    private var simplified = false
    private var displayChapter: NovelChapter?
    private var prefix = 0
    private var anchor = 0
    private var restoring = false
    private var onPosition: ((Int) -> Void)?
    private var wheelTargetY: CGFloat?
    private var wheelTimer: Timer?
    /// Set while the wheel animation itself moves the clip view, so its own bounds
    /// change does not look like a user scroll and cancel the animation.
    private var wheelScrolling = false

    init() {
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        reader = ReadingTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        borderType = .noBorder
        automaticallyAdjustsContentInsets = false
        contentInsets = .init()
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        reader.drawsBackground = false
        reader.isEditable = false
        reader.isSelectable = true
        reader.isVerticallyResizable = true
        reader.isHorizontallyResizable = false
        reader.minSize = .zero
        reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        reader.autoresizingMask = [.width]
        reader.textContainerInset = .init(width: 6, height: 5)
        reader.setAccessibilityLabel("小说正文")
        container.widthTracksTextView = true
        container.lineFragmentPadding = 1
        documentView = reader
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }
    public required init?(coder: NSCoder) { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { prepareKeyboardReading() }
    }

    private func prepareKeyboardReading() {
        Task { @MainActor [weak self] in
            guard let self, let window, window.isKeyWindow, window.isVisible,
                  !isHiddenOrHasHiddenAncestor, window.firstResponder !== reader else { return }
            let target = anchor
            restoring = true
            window.makeFirstResponder(reader)
            restore(target)
            restoring = false
        }
    }

    func show(_ page: NovelPageView) {
        let changed = bookID != page.bookID || chapterIndex != page.index
        onPosition = page.onPosition
        reader.turn = page.onTurn
        reader.previousEnd = page.onPreviousChapterEnd
        let scriptChanged = simplified != page.simplified
        guard changed || scriptChanged || size != page.fontSize else { return }
        if changed || scriptChanged {
            simplified = page.simplified
            displayChapter = simplified ? page.chapter.simplified() : page.chapter
        }
        guard let displayChapter else { return }
        let target = changed ? page.offset : anchor
        restoring = true
        defer { restoring = false }
        bookID = page.bookID
        chapterIndex = page.index
        size = page.fontSize
        let text = NSMutableAttributedString()
        let heading = displayChapter.title + "\n"
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacing = max(6, size * 0.6)
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = max(2, size * 0.22)
        bodyStyle.paragraphSpacing = 2
        text.append(NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: size + 1, weight: .semibold), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: headingStyle
        ]))
        prefix = text.length
        let font = NSFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size)
        text.append(NSAttributedString(string: displayChapter.text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyStyle
        ]))
        // A blank source line separates paragraphs. Keep its original character
        // offset for search and resume, but give it a modest typographic gap.
        let source = text.string as NSString
        let breaks = Self.paragraphBreaks.matches(in: text.string, range: NSRange(location: 0, length: source.length))
        for item in breaks {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 3), .paragraphStyle: NSParagraphStyle.default], range: item.range)
        }
        if let hit = page.highlight, NSMaxRange(hit) <= text.length - prefix {
            text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.42),
                              range: NSRange(location: prefix + hit.location, length: hit.length))
        }
        storage.setAttributedString(text)
        restore(target)
        if changed { prepareKeyboardReading() }
    }

    /// Chapters at least this long (UTF-16 units) reflow once a width change settles;
    /// a full reflow of 1 MiB takes about 115 ms, too slow for every drag step.
    private static let deferredReflowLength = 50_000
    private static let reflowDelay: TimeInterval = 0.15
    private var reflowTimer: Timer?
    /// Content width of the last full layout; nil until the reader has a real size.
    private var laidOutWidth: CGFloat?

    public override func setFrameSize(_ newSize: NSSize) {
        guard bookID != nil, !restoring, frame.size != newSize else { super.setFrameSize(newSize); return }
        stopWheelAnimation()
        let target = anchor
        // Only a chapter already laid out at a real width defers; the first layout is immediate.
        let deferring = reflowTimer != nil
            || (laidOutWidth != nil && newSize.width != frame.width && storage.length >= Self.deferredReflowLength)
        restoring = true
        if deferring {
            // Keep wrapping at the old width while the edge moves; the passage stays on screen.
            container.widthTracksTextView = false
            super.setFrameSize(newSize)
            scheduleReflow()
        } else {
            super.setFrameSize(newSize)
            restore(target)
        }
        restoring = false
    }

    private func scheduleReflow() {
        reflowTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reflowDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reflowTimer = nil
                self.restoring = true
                self.restore(self.anchor)
                self.restoring = false
            }
        }
        reflowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func restore(_ target: Int) {
        stopWheelAnimation()
        reflowTimer?.invalidate()
        reflowTimer = nil
        if !container.widthTracksTextView {
            container.widthTracksTextView = true
            container.size = NSSize(width: max(0, contentSize.width - 2 * reader.textContainerInset.width),
                                    height: container.size.height)
        }
        anchor = target
        guard contentSize.width > 1, contentSize.height > 1, storage.length > 0 else { return }
        laidOutWidth = contentSize.width
        let inset = NSSize(width: contentSize.width < 140 ? 2 : 6, height: contentSize.height < 40 ? 1 : 5)
        if reader.textContainerInset != inset { reader.textContainerInset = inset }
        reader.setFrameSize(.init(width: contentSize.width, height: max(1, reader.frame.height)))
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).height + 2 * reader.textContainerInset.height)
        reader.setFrameSize(.init(width: contentSize.width, height: max(contentSize.height, height)))
        // AppKit may shift a growing text view upward inside its clip view.
        // Use document coordinates for both saving and restoring text positions.
        reader.setFrameOrigin(.zero)
        let glyph = manager.glyphIndexForCharacter(at: min(storage.length - 1, prefix + target))
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = target == 0 ? 0 : rect.minY + reader.textContainerOrigin.y
        contentView.scroll(to: .init(x: 0, y: min(y, max(0, height - contentSize.height))))
        reflectScrolledClipView(contentView)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
              event.scrollingDeltaY != 0, reader.frame.height > contentSize.height else {
            stopWheelAnimation()
            super.scrollWheel(with: event)
            return
        }
        // A mouse wheel can deliver a large accelerated delta in one event. Keep
        // some of the current passage visible and ease successive steps together.
        let step = min(max(20, abs(event.scrollingDeltaY) * 22), max(20, contentSize.height * 0.38))
        let limit = reader.frame.height - contentSize.height
        let base = wheelTargetY ?? contentView.bounds.minY
        wheelTargetY = min(max(0, base + (event.scrollingDeltaY < 0 ? step : -step)), limit)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            contentView.scroll(to: NSPoint(x: 0, y: wheelTargetY ?? base))
            reflectScrolledClipView(contentView)
            stopWheelAnimation()
            return
        }
        guard wheelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let target = self.wheelTargetY else { self.stopWheelAnimation(); return }
                let current = self.contentView.bounds.minY
                let remaining = target - current
                let next = abs(remaining) < 0.5 ? target : current + remaining * 0.28
                self.wheelScrolling = true
                self.contentView.scroll(to: NSPoint(x: 0, y: next))
                self.reflectScrolledClipView(self.contentView)
                self.wheelScrolling = false
                if next == target { self.stopWheelAnimation() }
            }
        }
        wheelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWheelAnimation() {
        wheelTimer?.invalidate()
        wheelTimer = nil
        wheelTargetY = nil
    }

    @objc private func scrolled() {
        // A drag of the scroller must win over a wheel animation still in flight.
        if !restoring && !wheelScrolling { stopWheelAnimation() }
        guard !restoring, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              manager.numberOfGlyphs > 0, contentSize.height > 1 else { return }
        let y = max(0, contentView.bounds.minY - reader.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: NSPoint(x: 1, y: y + 0.5), in: container)
        let position = max(0, manager.characterIndexForGlyph(at: min(glyph, manager.numberOfGlyphs - 1)) - prefix)
        if position != anchor { anchor = position; onPosition?(position) }
    }
}

private final class ReadingTextView: NSTextView {
    var turn: ((Int) -> Void)?
    var previousEnd: (() -> Void)?

    private func page(forward: Bool, repeated: Bool) {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        if forward {
            if visible.maxY < bounds.maxY - 1 { scrollPageDown(nil) }
            else if !repeated { turn?(1) }
        } else if visible.minY > bounds.minY + 1 { scrollPageUp(nil) }
        else if !repeated {
            if let previousEnd { previousEnd() } else { turn?(-1) }
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags.isEmpty {
            switch event.keyCode {
            case 123: turn?(-1); return
            case 124: turn?(1); return
            case 49, 121: page(forward: true, repeated: event.isARepeat); return
            case 116: page(forward: false, repeated: event.isARepeat); return
            case 125: scrollLineDown(nil); return
            case 126: scrollLineUp(nil); return
            default: break
            }
        } else if flags == .shift && event.keyCode == 49 {
            page(forward: false, repeated: event.isARepeat); return
        }
        super.keyDown(with: event)
    }
}
