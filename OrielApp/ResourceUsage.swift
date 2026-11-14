import Combine
import Darwin
import Foundation

/// What can be attributed to one mini window. All windows share the app process,
/// so this counts only the window's own work: terminal shells and their children,
/// the WebContent process behind each browser page, and the chapter text an open
/// novel keeps in memory. Shared window chrome stays out of the per-window numbers.
struct WindowResourceUsage: Equatable, Sendable {
    var memory: UInt64 = 0
    var cpu: Double = 0
    var terminalBytes: UInt64 = 0
    var webBytes: UInt64 = 0
    var textBytes: UInt64 = 0

    var isEmpty: Bool { memory == 0 && cpu < 0.05 }
    var memoryText: String { ResourceFormat.memory(memory) }
    var cpuText: String { ResourceFormat.cpu(cpu) }

    var helpText: String {
        guard !isEmpty else {
            return "没有可单独统计的终端或网页进程；主进程的共用开销不计入单窗。"
        }
        var parts: [String] = []
        if terminalBytes > 0 { parts.append("终端 \(ResourceFormat.memory(terminalBytes))") }
        if webBytes > 0 { parts.append("网页 \(ResourceFormat.memory(webBytes))") }
        if textBytes > 0 { parts.append("正文约 \(ResourceFormat.memory(textBytes))") }
        return parts.joined(separator: " · ") + "\n含后台页签；CPU 按单核 100% 计，只统计终端与网页进程。"
    }
}

/// The processes and text a mini window owns, collected on demand.
struct WindowResourceSources: Equatable, Sendable {
    var terminalPIDs: [pid_t] = []
    var webPIDs: [pid_t] = []
    var textBytes: UInt64 = 0
}

enum ResourceFormat {
    static func memory(_ bytes: UInt64) -> String {
        if bytes >= 1 << 30 { return String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) }
        if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
        if bytes >= 1 << 10 { return String(format: "%.0f KB", Double(bytes) / Double(1 << 10)) }
        return "\(bytes) B"
    }

    static func cpu(_ percent: Double) -> String {
        percent >= 99.95 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }
}

/// Reads physical footprint and CPU time for a process. `ri_user_time` and
/// `ri_system_time` are mach absolute ticks, so the sampler compares them with
/// `mach_absolute_time()` rather than with a wall clock.
enum ProcessUsageReader {
    /// `start` identifies the process for this PID, so a recycled PID is not
    /// mistaken for the one sampled two seconds earlier.
    static func usage(of pid: pid_t) -> (cpu: UInt64, memory: UInt64, start: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_user_time + info.ri_system_time, info.ri_phys_footprint, info.ri_proc_start_abstime)
    }

    /// Every descendant of `pid`, breadth first, so a running build or ssh counts
    /// for the terminal that started it.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        var index = 0
        while index < queue.count && result.count < 256 {
            let parent = queue[index]
            index += 1
            var buffer = [pid_t](repeating: 0, count: 128)
            let count = buffer.withUnsafeMutableBytes {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
            }
            for child in buffer.prefix(max(0, Int(count))) where child > 0 && child != parent && !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}

/// Samples the windows of the management window while it is open. Offsets are
/// small, but everything stays on the main actor and only a few processes are read.
@MainActor
final class ResourceSampler: ObservableObject {
    static let shared = ResourceSampler()
    static let interval: TimeInterval = 2

    @Published private(set) var windows: [UUID: WindowResourceUsage] = [:]
    private var timer: Timer?
    private var provider: (() -> [(id: UUID, sources: WindowResourceSources)])?
    private var lastCPU: [pid_t: (ticks: UInt64, start: UInt64, at: UInt64)] = [:]

    func start(windows: @escaping () -> [(id: UUID, sources: WindowResourceSources)]) {
        provider = windows
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        provider = nil
        lastCPU = [:]
        windows = [:]
    }

    func sample() {
        guard let provider else { return }
        let now = mach_absolute_time()
        var live: Set<pid_t> = []
        // Read each process once: a web process shared by two pages must not be
        // counted twice, and its CPU delta may only be taken once per interval.
        var readings: [pid_t: (memory: UInt64, cpu: Double)] = [:]

        func reading(_ pid: pid_t) -> (memory: UInt64, cpu: Double)? {
            if let cached = readings[pid] { return cached }
            guard pid > 0, let sample = ProcessUsageReader.usage(of: pid) else { return nil }
            let value = (memory: sample.memory,
                         cpu: percent(pid: pid, ticks: sample.cpu, start: sample.start, at: now))
            readings[pid] = value
            live.insert(pid)
            return value
        }

        var result: [UUID: WindowResourceUsage] = [:]
        for window in provider() {
            var usage = WindowResourceUsage()
            var seen: Set<pid_t> = []

            func add(_ pid: pid_t, terminal: Bool) {
                guard pid > 0, seen.insert(pid).inserted, let value = reading(pid) else { return }
                usage.memory += value.memory
                usage.cpu += value.cpu
                if terminal { usage.terminalBytes += value.memory }
                else { usage.webBytes += value.memory }
            }

            for shell in window.sources.terminalPIDs {
                add(shell, terminal: true)
                for child in ProcessUsageReader.descendants(of: shell) { add(child, terminal: true) }
            }
            for pid in window.sources.webPIDs { add(pid, terminal: false) }

            usage.textBytes = window.sources.textBytes
            usage.memory += window.sources.textBytes
            result[window.id] = usage
        }

        lastCPU = lastCPU.filter { live.contains($0.key) }
        if result != windows { windows = result }
    }

    private func percent(pid: pid_t, ticks: UInt64, start: UInt64, at now: UInt64) -> Double {
        defer { lastCPU[pid] = (ticks, start, now) }
        guard let last = lastCPU[pid], last.start == start, now > last.at, ticks >= last.ticks else { return 0 }
        return Double(ticks - last.ticks) / Double(now - last.at) * 100
    }
}
