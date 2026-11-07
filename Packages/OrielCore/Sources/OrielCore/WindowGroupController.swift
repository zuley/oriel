import Foundation
import CoreGraphics

/// Routes commands by stable window identity. Closing one window never retargets its events.
@MainActor
public final class WindowGroupController {
    public enum Emphasis: Equatable { case normal, highlighted, dimmed }
    private var hoveredWindow: UUID?

    public func hover(_ id: UUID?) {
        hoveredWindow = id.flatMap { snapshot(for: $0)?.isVisible == true ? $0 : nil }
    }
    public func endHover(_ id: UUID) {
        if hoveredWindow == id { hoveredWindow = nil }
    }
    public func emphasis(for id: UUID) -> Emphasis {
        guard let hoveredWindow else { return .normal }
        return id == hoveredWindow ? .highlighted : .dimmed
    }

    public enum Command {
        case setLocked(Bool)
        case hide
        case recover
        case close
        case automaticHiding(Bool, pointer: CGPoint)
        case pointer(CGPoint, editing: Bool)
        case frame(CGRect)
        case beginGeometry
        case endGeometry(pointer: CGPoint)
    }
    private var controllers: [UUID: WindowBehaviorController] = [:]
    private var order: [UUID] = []
    public init() {}

    public var snapshots: [WindowSnapshot] { order.compactMap { controllers[$0]?.snapshot } }
    public func snapshot(for id: UUID) -> WindowSnapshot? { controllers[id]?.snapshot }

    @discardableResult
    public func create(frame: CGRect) -> UUID {
        let controller = WindowBehaviorController()
        let id = controller.create(frame: frame)
        controllers[id] = controller
        order.append(id)
        return id
    }

    public func send(_ command: Command, to id: UUID) {
        guard let controller = controllers[id] else { return }
        switch command {
        case .setLocked(let locked): controller.setLocked(locked)
        case .hide: controller.hide()
        case .recover: controller.recover()
        case .close:
            controller.close()
            controllers.removeValue(forKey: id)
            order.removeAll { $0 == id }
        case .automaticHiding(let enabled, let pointer): controller.setAutomaticHiding(enabled, pointer: pointer)
        case .pointer(let pointer, let editing): controller.samplePointer(pointer, for: id, editing: editing)
        case .frame(let frame): controller.updateFrame(frame, for: id)
        case .beginGeometry: controller.beginGeometryChange(for: id)
        case .endGeometry(let pointer): controller.endGeometryChange(pointer: pointer, for: id)
        }
        if let hoveredWindow, snapshot(for: hoveredWindow)?.isVisible != true {
            self.hoveredWindow = nil
        }
    }
}
