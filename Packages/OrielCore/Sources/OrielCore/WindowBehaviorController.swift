import Foundation
import CoreGraphics

/// Desired window state. The AppKit adapter applies it to the actual window.
public struct WindowSnapshot: Equatable, Sendable {
    public enum FoldingEdge: Equatable, Sendable { case top, bottom }
    public let id: UUID
    public internal(set) var frame: CGRect
    public let opacity: Double
    public internal(set) var isVisible: Bool
    public internal(set) var isLocked: Bool
    public internal(set) var automaticHiding: Bool
    public internal(set) var automaticFolding = false
    public internal(set) var isFolded = false
    public internal(set) var foldingEdge: FoldingEdge = .top

    public var foldedFrame: CGRect {
        let height = min(28, frame.height)
        return CGRect(x: frame.minX, y: foldingEdge == .top ? frame.maxY - height : frame.minY,
                      width: frame.width, height: height)
    }

    /// The saved frame always remains expanded; only the displayed body becomes a bar.
    public var presentationFrame: CGRect {
        guard isFolded else { return frame }
        return foldedFrame
    }
}

@MainActor
public final class WindowBehaviorController {
    public private(set) var snapshot: WindowSnapshot?
    private var previousPointer: CGPoint?
    private var geometryWindowID: UUID?
    private var visibleFrame: CGRect?

    public init() {}

    public func updateVisibleFrame(_ frame: CGRect) {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        if visibleFrame != frame { previousPointer = nil }
        visibleFrame = frame
    }

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
        if snapshot?.automaticFolding == true { previousPointer = nil }
        fitFoldingWindow()
        if locked { snapshot?.isFolded = false }
    }

    public func updateFrame(_ frame: CGRect, for id: UUID) {
        guard let state = snapshot, state.id == id, state.frame != frame else { return }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0 else { return }
        previousPointer = nil
        snapshot?.frame = frame
        if geometryWindowID == nil { fitFoldingWindow() }
    }

    public func beginGeometryChange(for id: UUID) {
        guard let state = snapshot, state.id == id, state.isVisible, !state.isLocked else { return }
        geometryWindowID = id
        previousPointer = nil
        snapshot?.isFolded = false
    }

    public func endGeometryChange(pointer: CGPoint, for id: UUID) {
        guard let state = snapshot, state.id == id, geometryWindowID == id else { return }
        geometryWindowID = nil
        previousPointer = nil
        if state.automaticHiding {
            snapshot?.isVisible = containsInclusive(pointer, in: state.frame.insetBy(dx: -12, dy: -12))
        } else if state.automaticFolding {
            samplePointer(pointer, for: id)
        }
    }

    public func setAutomaticHiding(_ enabled: Bool, pointer: CGPoint) {
        if enabled { fitFoldingWindow() }
        guard let state = snapshot else { return }
        previousPointer = nil
        snapshot?.automaticHiding = enabled
        if enabled {
            snapshot?.automaticFolding = false
            snapshot?.isFolded = false
            snapshot?.foldingEdge = .top
        }
        snapshot?.isVisible = !enabled || containsInclusive(pointer, in: state.frame.insetBy(dx: -12, dy: -12))
    }

    public func setAutomaticFolding(_ enabled: Bool, pointer: CGPoint) {
        if !enabled { fitFoldingWindow() }
        guard let state = snapshot else { return }
        geometryWindowID = nil
        previousPointer = nil
        snapshot?.automaticFolding = enabled
        if !state.automaticFolding { snapshot?.foldingEdge = .top }
        fitFoldingWindow()
        let fitted = snapshot?.frame ?? state.frame
        snapshot?.isFolded = enabled && !state.isLocked
            && !containsInclusive(pointer, in: fitted.insetBy(dx: -8, dy: -8))
        if !enabled { snapshot?.foldingEdge = .top }
        if enabled {
            snapshot?.automaticHiding = false
            snapshot?.isVisible = true
            previousPointer = pointer
        }
    }

    public func samplePointer(_ pointer: CGPoint, for id: UUID, editing: Bool = false) {
        guard snapshot?.id == id,
              geometryWindowID != id else { return }
        fitFoldingWindow()
        guard let state = snapshot else { return }
        if state.automaticFolding {
            guard state.isVisible, !state.isLocked else { return }
            defer { previousPointer = pointer }
            if editing { snapshot?.isFolded = false; return }
            let hitFrame = state.isFolded ? state.presentationFrame : state.frame.insetBy(dx: -8, dy: -8)
            // A coalesced sample may already be past the thin bar. Reveal only
            // when that path crosses the bar and ends inside the expanded body.
            let crossedBar = state.isFolded && containsInclusive(pointer, in: state.frame)
                && previousPointer.map { segmentIntersects(state.foldedFrame, from: $0, to: pointer) } == true
            snapshot?.isFolded = !containsInclusive(pointer, in: hitFrame) && !crossedBar
            return
        }
        guard state.automaticHiding else { return }
        defer { previousPointer = pointer }
        if editing && state.isVisible && !state.isLocked { return }
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
        snapshot?.automaticFolding = false
        snapshot?.isFolded = false
    }

    public func recover() {
        fitFoldingWindow()
        geometryWindowID = nil
        previousPointer = nil
        snapshot?.isVisible = true
        snapshot?.isLocked = false
        snapshot?.automaticHiding = false
        snapshot?.automaticFolding = false
        snapshot?.isFolded = false
        snapshot?.foldingEdge = .top
    }

    public func close() {
        geometryWindowID = nil
        previousPointer = nil
        snapshot = nil
        visibleFrame = nil
    }

    /// Preserve the bar's position, choosing the side with room for the expanded body.
    private func fitFoldingWindow() {
        guard let state = snapshot, state.automaticFolding, let screen = visibleFrame else { return }
        let bar = state.foldedFrame
        let width = min(state.frame.width, screen.width)
        let height = min(state.frame.height, screen.height)
        let barHeight = min(28, height)
        let x = min(max(bar.minX, screen.minX), screen.maxX - width)
        let barY = min(max(bar.minY, screen.minY), screen.maxY - barHeight)
        let down = barY + barHeight - height
        let up = barY
        let edge: WindowSnapshot.FoldingEdge
        let candidateY: CGFloat
        if state.foldingEdge == .bottom && up + height <= screen.maxY {
            edge = .bottom; candidateY = up
        } else if down >= screen.minY {
            edge = .top; candidateY = down
        } else if up + height <= screen.maxY {
            edge = .bottom; candidateY = up
        } else {
            edge = screen.maxY - barY >= barY + barHeight - screen.minY ? .bottom : .top
            candidateY = edge == .bottom ? up : down
        }
        let y = min(max(candidateY, screen.minY), screen.maxY - height)
        let fitted = CGRect(x: x, y: y, width: width, height: height)
        if fitted != state.frame || edge != state.foldingEdge { previousPointer = nil }
        snapshot?.frame = fitted
        snapshot?.foldingEdge = edge
    }

    private func segmentIntersects(_ rect: CGRect, from start: CGPoint, to end: CGPoint) -> Bool {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return false }
        var entry: CGFloat = 0
        var exit: CGFloat = 1
        let axes = [(start.x, end.x - start.x, rect.minX, rect.maxX),
                    (start.y, end.y - start.y, rect.minY, rect.maxY)]
        for (origin, delta, lower, upper) in axes {
            if delta == 0 {
                if origin < lower || origin > upper { return false }
            } else {
                let first = (lower - origin) / delta
                let last = (upper - origin) / delta
                entry = max(entry, min(first, last))
                exit = min(exit, max(first, last))
                if entry > exit { return false }
            }
        }
        return true
    }

    private func containsInclusive(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}
