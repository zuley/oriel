import AppKit
import XCTest

@MainActor
final class WindowChromeLayoutTests: XCTestCase {
    func testToolbarAndTabSpaceRemainStableAcrossContentLockAndResize() {
        let chrome = MiniWindowChromeView(actions: .init(
            addTab: {}, selectTab: { _ in }, closeTab: { _ in }, toggleAutomaticHiding: {},
            settings: { _ in }, toggleLock: {}, hide: {}, close: {}, drag: { _ in }))
        chrome.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        let reading = NSView()
        chrome.setTabs([(1, "便签")], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 328)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 32)
        chrome.setTabs([(1, "便签"), (2, "终端")], selected: 1)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(reading.frame.height, 304)
        XCTAssertEqual(reading.convert(reading.bounds, to: chrome).minY, 56)

        let terminal = NSView()
        chrome.showTerminal(terminal)
        XCTAssertEqual(terminal.frame.height, 296)
        chrome.update(isLocked: true, automaticHiding: true)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 296)
        chrome.update(isLocked: false, automaticHiding: false)
        chrome.setFrameSize(NSSize(width: 120, height: 90))
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.height, 26)
        chrome.setTabs([(1, "便签")], selected: 1)
        chrome.showReadingSurface(reading)
        XCTAssertEqual(reading.frame.height, 58)
        let labels = chrome.subviews.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains("新建页签"))
        XCTAssertFalse(labels.contains { $0.contains("沉浸") })
    }
}
