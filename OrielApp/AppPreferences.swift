import Foundation
import Combine

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var width: Double { didSet { let value = Self.bounded(width, 120...900, fallback: 280); if width != value { width = value; return }; defaults.set(width, forKey: "window.defaults.width") } }
    @Published var height: Double { didSet { let value = Self.bounded(height, 90...1200, fallback: 360); if height != value { height = value; return }; defaults.set(height, forKey: "window.defaults.height") } }
    @Published var backgroundOpacity: Double { didSet { let value = Self.bounded(backgroundOpacity, 0...1, fallback: 0.75); if backgroundOpacity != value { backgroundOpacity = value; return }; defaults.set(backgroundOpacity, forKey: "window.defaults.background") } }
    @Published var contentOpacity: Double { didSet { let value = Self.bounded(contentOpacity, 0...1, fallback: 0.75); if contentOpacity != value { contentOpacity = value; return }; defaults.set(contentOpacity, forKey: "window.defaults.content") } }
    @Published var openAtLaunch: Bool { didSet { defaults.set(openAtLaunch, forKey: "management.openAtLaunch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        width = Self.bounded(defaults.object(forKey: "window.defaults.width") as? Double ?? 280, 120...900, fallback: 280)
        height = Self.bounded(defaults.object(forKey: "window.defaults.height") as? Double ?? 360, 90...1200, fallback: 360)
        backgroundOpacity = Self.bounded(defaults.object(forKey: "window.defaults.background") as? Double ?? 0.75, 0...1, fallback: 0.75)
        contentOpacity = Self.bounded(defaults.object(forKey: "window.defaults.content") as? Double ?? 0.75, 0...1, fallback: 0.75)
        openAtLaunch = defaults.object(forKey: "management.openAtLaunch") as? Bool ?? true
    }

    func reset() {
        width = 280; height = 360
        backgroundOpacity = 0.75; contentOpacity = 0.75
        openAtLaunch = true
    }

    private static func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
