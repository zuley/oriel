import Foundation
import CoreGraphics

/// Desired window state. The AppKit adapter applies it to the actual window.
public struct WindowSnapshot: Equatable, Sendable {
    public let id: UUID
    public internal(set) var frame: CGRect
    public let opacity: Double
    public internal(set) var isVisible: Bool
    public internal(set) var isLocked: Bool
    public internal(set) var automaticHiding: Bool
}

@MainActor
public final class WindowBehaviorController {
    public private(set) var snapshot: WindowSnapshot?
    private var previousPointer: CGPoint?
    private var geometryWindowID: UUID?

    public init() {}

    @discardableResult
    public func create(frame: CGRect, opacity: Double = 1) -> UUID {
        if let snapshot { return snapshot.id }
        geometryWindowID = nil
        previousPointer = nil
        let id = UUID()
        snapshot = WindowSnapshot(id: id, frame: frame, opacity: opacity,
                                  isVisible: true, isLocked: false, automaticHiding: false)
        return id
    }

    public func setLocked(_ locked: Bool) {
        if locked && geometryWindowID != nil {
            geometryWindowID = nil
            previousPointer = nil
        }
        snapshot?.isLocked = locked
    }

    public func updateFrame(_ frame: CGRect, for id: UUID) {
        guard let state = snapshot, state.id == id, state.frame != frame else { return }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else { return }
        previousPointer = nil
        snapshot?.frame = frame
    }

    public func beginGeometryChange(for id: UUID) {
        guard let state = snapshot, state.id == id, state.isVisible, !state.isLocked else { return }
        geometryWindowID = id
        previousPointer = nil
    }

    public func endGeometryChange(pointer: CGPoint, for id: UUID) {
        guard let state = snapshot, state.id == id, geometryWindowID == id else { return }
        geometryWindowID = nil
        previousPointer = nil
        if state.automaticHiding {
            snapshot?.isVisible = containsInclusive(pointer, in: state.frame.insetBy(dx: -12, dy: -12))
        }
    }

    public func setAutomaticHiding(_ enabled: Bool, pointer: CGPoint) {
        guard let state = snapshot else { return }
        previousPointer = nil
        snapshot?.automaticHiding = enabled
        snapshot?.isVisible = !enabled || containsInclusive(pointer, in: state.frame.insetBy(dx: -12, dy: -12))
    }

    public func samplePointer(_ pointer: CGPoint, for id: UUID) {
        guard let state = snapshot, state.id == id, state.automaticHiding,
              geometryWindowID != id else { return }
        defer { previousPointer = pointer }
        let outer = state.frame.insetBy(dx: -12, dy: -12)
        let inner = state.frame.insetBy(dx: 12, dy: 12)
        // Inner and outer boundaries belong to the wake zone. Only the strict
        // interior is excluded, and a visible window may remain in that interior.
        let insideInner = pointer.x > inner.minX && pointer.x < inner.maxX
            && pointer.y > inner.minY && pointer.y < inner.maxY
        // Consecutive samples can skip the narrow edge zone. Entering from
        // outside still crosses an edge, even when the next sample is central.
        let enteredFromOutside = previousPointer.map { !containsInclusive($0, in: outer) } ?? false
        snapshot?.isVisible = containsInclusive(pointer, in: outer)
            && (state.isVisible || !insideInner || enteredFromOutside)
    }

    /// Collapse into the menu bar without closing or allowing hover to reopen it.
    public func hide() {
        geometryWindowID = nil
        previousPointer = nil
        snapshot?.isVisible = false
        snapshot?.automaticHiding = false
    }

    public func recover() {
        geometryWindowID = nil
        previousPointer = nil
        snapshot?.isVisible = true
        snapshot?.isLocked = false
        snapshot?.automaticHiding = false
    }

    public func close() {
        geometryWindowID = nil
        previousPointer = nil
        snapshot = nil
    }

    private func containsInclusive(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}
