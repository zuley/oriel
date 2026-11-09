import AppKit
import XCTest

@MainActor
final class BrowserAddressLayoutTests: XCTestCase {
    func testAddressBaselineSurvivesFirstAutofocusResizingAndRefocusing() throws {
        _ = NSApplication.shared
        let suite = "browser-address-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 280, height: 300),
                                  bookmarks: BrowserBookmarks(defaults: defaults), defaults: defaults)
        let panel = NSPanel(contentRect: browser.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = browser
        defer { browser.dispose(); panel.close() }
        let field = try XCTUnwrap(descendants(browser).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "地址栏" })
        // The app focuses a newly attached browser before AppKit's next layout pass.
        browser.focusAddress()
        browser.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(field.currentEditor(), "Must exercise the real field-editor path")
        editor.string = "example.com"
        let focused = try textInk(in: field, name: "focused")
        for width: CGFloat in [120, 180, 280, 480] {
            browser.setFrameSize(NSSize(width: width, height: 300))
            browser.needsLayout = true
            browser.layoutSubtreeIfNeeded()
            let resized = try textInk(in: field, name: "focused-\(Int(width))")
            XCTAssertEqual(resized.midY, focused.midY, accuracy: 1,
                           "Resizing the browser to \(width) must preserve the focused text baseline")
        }
        browser.setFrameSize(NSSize(width: 280, height: 300))
        browser.needsLayout = true
        browser.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(nil)
        field.stringValue = "example.com"
        let idle = try textInk(in: field, name: "idle")
        XCTAssertEqual(focused.midY, idle.midY, accuracy: 1,
                       "Address text must not jump vertically when a new tab autofocuses it")
        // The small vertical margins inside the 22-point pill must still focus it.
        let pill = try XCTUnwrap(field.superview)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        pill.mouseDown(with: click)
        XCTAssertTrue(browser.isEditingAddress)
        let refocused = try XCTUnwrap(field.currentEditor())
        refocused.string = "example.com"
        XCTAssertEqual(try textInk(in: field, name: "refocused").midY, idle.midY, accuracy: 1)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }

    private func textInk(in field: NSTextField, name: String) throws -> CGRect {
        let bounds = field.bounds
        let bitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: bounds))
        field.cacheDisplay(in: bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / bounds.height
        var rows: [Int] = []
        // Ignore the caret at the leading edge; compare glyph rows, not focus outlines.
        for y in 0..<bitmap.pixelsHigh {
            for x in Int(6 * scale)..<max(Int(6 * scale), bitmap.pixelsWide - Int(2 * scale)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if components.max()! - components.min()! < 0.08, components.max()! < 0.85 {
                    rows.append(y)
                    break
                }
            }
        }
        let first = try XCTUnwrap(rows.min(), "Expected visible address glyphs in \(name)")
        let last = try XCTUnwrap(rows.max())
        let ink = CGRect(x: 0, y: CGFloat(first) / scale, width: bounds.width, height: CGFloat(last - first + 1) / scale)
        return field.convert(ink, to: field.superview)
    }
}
