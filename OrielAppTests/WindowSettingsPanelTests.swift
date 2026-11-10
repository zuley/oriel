import AppKit
import XCTest

@MainActor
final class WindowSettingsPanelTests: XCTestCase {
    /// Check the actual OS-specific material, not just a semantic material enum.
    private func controls(in view: NSView) throws -> NSView {
        XCTAssertEqual(view.frame.size, NSSize(width: 224, height: 72))
        XCTAssertEqual(view.alphaValue, 1)
        XCTAssertEqual(view.layer?.backgroundColor?.alpha ?? 0, 0, "No opaque fill may cover the material.")
        if #available(macOS 26, *) {
            let glass = try XCTUnwrap(view as? NSGlassEffectView,
                "On macOS 26 the legacy menu material rendered as a solid fill over patterned backgrounds.")
            XCTAssertEqual(glass.style, .regular)
            XCTAssertEqual(glass.cornerRadius, 8)
            XCTAssertNil(glass.tintColor)
            let content = try XCTUnwrap(glass.contentView)
            XCTAssertEqual(content.frame.size, view.bounds.size)
            XCTAssertEqual(content.alphaValue, 1)
            XCTAssertTrue(content.subviews.allSatisfy { $0.alphaValue == 1 })
            return content
        } else {
            let effect = try XCTUnwrap(view as? NSVisualEffectView)
            XCTAssertEqual(effect.material, .menu)
            XCTAssertEqual(effect.blendingMode, .behindWindow)
            XCTAssertEqual(effect.state, .active)
            XCTAssertEqual(effect.layer?.cornerRadius, 8)
            XCTAssertEqual(effect.layer?.masksToBounds, true)
            return effect
        }
    }

    func testSettingsUseNativeGlassOnSupportedSystemsWithoutFadingControls() throws {
        let controller = WindowSettingsController(background: 0.25, content: 0.5) { _, _ in }
        let content = try controls(in: controller.view)
        XCTAssertEqual(content.subviews.compactMap { $0 as? NSSlider }.count, 2)
        XCTAssertEqual(content.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue),
                       ["内容透明度", "背景透明度"])
    }

    func testShowingAndReopeningPanelPreserveMaterialAndDismissal() throws {
        let owner = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 280, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 200, y: 320, width: 22, height: 28))
        owner.contentView?.addSubview(anchor)
        let panel = WindowSettingsPanel()
        panel.contentViewController = WindowSettingsController(background: 0, content: 0) { _, _ in }
        defer { panel.performClose(nil); panel.contentViewController = nil; owner.close() }
        var dismissals = 0
        for _ in 0..<2 {
            panel.onDismiss = { dismissals += 1 }
            panel.show(below: anchor)
            _ = try controls(in: try XCTUnwrap(panel.contentViewController?.view))
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(panel.backgroundColor, .clear)
            XCTAssertEqual(panel.alphaValue, 1, "Even zero-opacity owners must leave settings usable.")
            XCTAssertTrue(panel.hasShadow)
            XCTAssertTrue(panel.parent === owner)
            panel.performClose(nil)
            XCTAssertNil(panel.parent)
            XCTAssertFalse(panel.isVisible)
        }
        XCTAssertEqual(dismissals, 2)
    }

    func testSlidersKeepValuesContinuousActionsAndLabels() throws {
        var changes: [(Double, Double)] = []
        let controller = WindowSettingsController(background: 0.25, content: 0.75) {
            changes.append(($0, $1))
        }
        let sliders = try controls(in: controller.view).subviews.compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 2)
        let content = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "内容透明度" })
        let background = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "背景透明度" })
        XCTAssertEqual(content.doubleValue, 0.75)
        XCTAssertEqual(background.doubleValue, 0.25)
        XCTAssertTrue(sliders.allSatisfy { $0.isContinuous && $0.minValue == 0 && $0.maxValue == 1 })
        content.doubleValue = 0
        XCTAssertTrue(content.sendAction(try XCTUnwrap(content.action), to: content.target))
        XCTAssertEqual(changes.last?.0, 0.25)
        XCTAssertEqual(changes.last?.1, 0)
        background.doubleValue = 1
        XCTAssertTrue(background.sendAction(try XCTUnwrap(background.action), to: background.target))
        XCTAssertEqual(changes.last?.0, 1)
        XCTAssertEqual(changes.last?.1, 0)
    }
}
