import Foundation
import Combine

/// A ready-made window shape for new mini windows. Choosing one writes the same
/// four values the size fields and opacity sliders own, so `AppModel.create` and
/// `MiniPanel.applyDefaults` keep reading them unchanged. Shapes share the factory
/// opacity so a preset is purely about geometry.
struct WindowPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let width: Double
    let height: Double
    let backgroundOpacity: Double
    let contentOpacity: Double

    static let all: [WindowPreset] = [
        .init(id: "portrait", title: "竖版", summary: "280 × 360 · 窄长",
              width: 280, height: 360, backgroundOpacity: 0.75, contentOpacity: 0.75),
        .init(id: "landscape", title: "横版", summary: "480 × 300 · 宽扁",
              width: 480, height: 300, backgroundOpacity: 0.75, contentOpacity: 0.75),
        .init(id: "square", title: "正方形", summary: "360 × 360 · 方正",
              width: 360, height: 360, backgroundOpacity: 0.75, contentOpacity: 0.75)
    ]

    /// Opacities use a tolerance: a slider can leave a rounding residue behind.
    func matches(width: Double, height: Double, background: Double, content: Double) -> Bool {
        width == self.width && height == self.height &&
        abs(background - backgroundOpacity) < 0.001 && abs(content - contentOpacity) < 0.001
    }
}

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

    /// The preset matching the saved values, or nil when they were customised.
    var currentPreset: WindowPreset? {
        WindowPreset.all.first {
            $0.matches(width: width, height: height,
                       background: backgroundOpacity, content: contentOpacity)
        }
    }

    /// Selecting a preset is the only write the picker needs.
    func apply(_ preset: WindowPreset) {
        width = preset.width
        height = preset.height
        backgroundOpacity = preset.backgroundOpacity
        contentOpacity = preset.contentOpacity
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
