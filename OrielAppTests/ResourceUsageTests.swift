import AppKit
import XCTest

@MainActor
final class ResourceUsageTests: XCTestCase {
    func testMemoryAndCPUFormatting() {
        XCTAssertEqual(ResourceFormat.memory(0), "0 B")
        XCTAssertEqual(ResourceFormat.memory(1024), "1 KB")
        XCTAssertEqual(ResourceFormat.memory(1_500_000), "1.4 MB")
        XCTAssertEqual(ResourceFormat.memory(2 << 30), "2.0 GB")
        XCTAssertEqual(ResourceFormat.cpu(0.04), "0.0%")
        XCTAssertEqual(ResourceFormat.cpu(12.34), "12.3%")
        XCTAssertEqual(ResourceFormat.cpu(120.4), "120%")
    }

    func testWindowWithoutOwnProcessesExplainsItself() {
        let usage = WindowResourceUsage()
        XCTAssertTrue(usage.isEmpty)
        XCTAssertEqual(usage.memoryText, "0 B")
        XCTAssertTrue(usage.helpText.contains("共用"))
    }

    func testSamplerAddsAWindowsProcessesAndText() throws {
        let window = UUID()
        let sampler = ResourceSampler()
        sampler.start {
            [(id: window, sources: WindowResourceSources(terminalPIDs: [getpid()], textBytes: 2048))]
        }
        defer { sampler.stop() }
        let sampled = sampler.windows[window]
        let usage = try XCTUnwrap(sampled)
        XCTAssertGreaterThan(usage.memory, 2048)
        XCTAssertEqual(usage.textBytes, 2048)
        XCTAssertEqual(usage.terminalBytes, usage.memory - 2048)
        XCTAssertEqual(usage.webBytes, 0)
        XCTAssertFalse(usage.isEmpty)
    }

    func testProcessReaderSeesAChildAndItsFootprint() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let usage = try XCTUnwrap(ProcessUsageReader.usage(of: child.processIdentifier))
        XCTAssertGreaterThan(usage.memory, 0)
        XCTAssertTrue(ProcessUsageReader.descendants(of: getpid()).contains(child.processIdentifier))
        XCTAssertNil(ProcessUsageReader.usage(of: 0))
        XCTAssertNil(ProcessUsageReader.usage(of: 4_000_000))
    }

    func testCPUTicksGrowWhileTheProcessRuns() throws {
        let first = try XCTUnwrap(ProcessUsageReader.usage(of: getpid())).cpu
        let end = Date().addingTimeInterval(0.2)
        var spins = 0
        while Date() < end { spins &+= 1 }
        let second = try XCTUnwrap(ProcessUsageReader.usage(of: getpid())).cpu
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(spins, 0)
    }

    func testSamplerReportsCPUForABusyProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        try child.run()
        defer { child.terminate() }

        let window = UUID()
        let sampler = ResourceSampler()
        sampler.start {
            [(id: window, sources: WindowResourceSources(terminalPIDs: [child.processIdentifier]))]
        }
        defer { sampler.stop() }
        // Prime the baseline, let the child burn a core, then sample again.
        Thread.sleep(forTimeInterval: 0.4)
        sampler.sample()
        let sampled = sampler.windows[window]
        let usage = try XCTUnwrap(sampled)
        XCTAssertGreaterThan(usage.cpu, 30, "CPU time must come from mach ticks, not nanoseconds.")
        XCTAssertLessThan(usage.cpu, 400)
    }

    func testBrowserPageReportsItsWebContentProcess() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let browser = BrowserView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = browser
        window.orderBack(nil)
        browser.showStartPage()
        let deadline = Date().addingTimeInterval(5)
        while browser.webProcessID == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try XCTUnwrap(browser.webProcessID, "WebKit no longer exposes its web process.")
        XCTAssertGreaterThan(pid, 0)
        browser.dispose()
    }
}
