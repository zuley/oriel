import Combine
import SwiftUI

struct ManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ManagementState
    @State private var hoveredSection: ManagementState.Section?
    private let accent = OrielPalette.tint

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .foregroundStyle(OrielPalette.text)
        .background(Color(nsColor: OrielPalette.background))
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let url = Bundle.main.url(forResource: "OrielMark", withExtension: "pdf", subdirectory: "Brand"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                }
                Text("Oriel").font(.system(size: 20, weight: .semibold))
            }
            .padding(.leading, 10)
            .padding(.top, 40)
            .padding(.bottom, 28)

            VStack(spacing: 2) {
                ForEach(ManagementState.Section.allCases) { section in
                    sectionButton(section)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            Text("关闭主界面，小窗仍可用")
                .font(.system(size: 10))
                .foregroundStyle(OrielPalette.mutedText)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
        }
        .frame(width: 164)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: OrielPalette.sidebar))
    }

    private func sectionButton(_ section: ManagementState.Section) -> some View {
        let selected = section == state.section
        return Button {
            state.section = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? accent : OrielPalette.mutedText)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? OrielPalette.text : OrielPalette.mutedText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(background(for: section, selected: selected), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredSection = section }
            else if hoveredSection == section { hoveredSection = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredSection)
        .animation(.easeOut(duration: 0.12), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func background(for section: ManagementState.Section, selected: Bool) -> Color {
        if selected { return Color(nsColor: OrielPalette.selection) }
        return hoveredSection == section ? Color(nsColor: OrielPalette.hover).opacity(0.6) : .clear
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch state.section {
                case .workspace: WorkspaceManagementView(model: model, isPresented: state.isPresented)
                case .settings: ManagementSettingsView(settings: model.preferences, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 40)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: OrielPalette.background))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.section.rawValue).font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(OrielPalette.mutedText)
            }
            Spacer(minLength: 0)
            if state.section == .workspace {
                Button { model.create() } label: {
                    Label("新建小窗", systemImage: "plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(OrielPalette.tint)
            }
        }
        .padding(.bottom, 24)
    }

    private var subtitle: String {
        switch state.section {
        case .workspace: "\(model.windows.count) 个小窗"
        case .settings: "新小窗默认值与本地数据"
        }
    }
}

private struct WorkspaceManagementView: View {
    @ObservedObject var model: AppModel
    let isPresented: Bool
    @ObservedObject private var sampler = ResourceSampler.shared
    @State private var hovered: UUID?

    var body: some View {
        Group {
            if model.windows.isEmpty {
                ManagementEmptyView(icon: "rectangle.on.rectangle", title: "还没有小窗",
                                    detail: "创建小窗后，在小窗中添加和使用内容。") { EmptyView() }
            } else {
                GeometryReader { viewport in
                    ScrollView([.vertical, .horizontal]) {
                        ThumbnailFlowLayout(spacing: 26, wrapWidth: viewport.size.width) {
                            ForEach(model.windows) { window in
                                ManagedWindowThumbnail(window: window, isPresented: isPresented,
                                                       viewportSize: viewport.size,
                                                       highlighted: hovered == window.id,
                                                       usage: sampler.windows[window.id] ?? WindowResourceUsage())
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside { hovered = window.id }
                                        else if hovered == window.id { hovered = nil }
                                        model.hoverWindow(window.id, inside: inside)
                                    }
                                    .onDisappear {
                                        if hovered == window.id { hovered = nil }
                                        model.hoverWindow(window.id, inside: false)
                                    }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height,
                               alignment: .topLeading)
                    }.coordinateSpace(name: "thumbnailViewport")
                }
            }
        }
        .font(.system(size: 12))
        .onDisappear { model.clearWindowHover() }
    }
}

private struct ThumbnailFlowLayout: Layout {
    let spacing: CGFloat
    let wrapWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(for: subviews)
        return CGSize(width: max(proposal.width ?? 0, result.size.width), height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(for: subviews)
        for (subview, point) in zip(subviews, result.positions) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                          proposal: .unspecified)
        }
    }

    private func arrangement(for subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > max(wrapWidth, 1) {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (positions, CGSize(width: max(wrapWidth, widest), height: y + rowHeight))
    }
}

private struct ManagedWindowThumbnail: View {
    @ObservedObject var window: MiniWindowSession
    let isPresented: Bool
    let viewportSize: CGSize
    let highlighted: Bool
    let usage: WindowResourceUsage
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var isInViewport = false
    @State private var closing = false
    @State private var renaming = false
    @State private var nameDraft = ""
    var body: some View {
        if let snapshot = window.snapshot {
            let width = thumbnailHeight * max(snapshot.frame.width, 1) / max(snapshot.frame.height, 1)
            VStack(alignment: .leading, spacing: 7) {
                Button { window.showFromWorkspace() } label: {
                    WindowThumbnail(width: width, image: window.thumbnail, highlighted: highlighted)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(snapshot.isVisible ? window.name : "\(window.name) · 已隐藏")
                .accessibilityLabel(snapshot.isVisible ? window.name : "\(window.name)，已隐藏")
                .contextMenu {
                    Button(snapshot.isVisible ? "隐藏" : "显示") {
                        if snapshot.isVisible { window.hide() }
                        else { window.showFromWorkspace() }
                    }
                    Button("重命名") {
                        nameDraft = window.name
                        renaming = true
                    }
                    Divider()
                    Button("关闭", role: .destructive) { closing = true }
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    geometry.frame(in: .named("thumbnailViewport"))
                        .intersects(CGRect(origin: .zero, size: viewportSize))
                } action: { visible in
                    isInViewport = visible
                    if visible && isPresented { window.refreshThumbnail() }
                }
                .onReceive(refresh) { _ in if isPresented && isInViewport { window.refreshThumbnail() } }
                .onChange(of: isPresented) { _, visible in
                    if visible && isInViewport { window.refreshThumbnail() }
                }
                .alert("关闭\(window.name)？", isPresented: $closing) {
                    Button("取消", role: .cancel) {}
                    // This alert is the confirmation, so it also covers running terminal commands.
                    Button("关闭", role: .destructive) { window.close(endingJobs: true) }
                } message: {
                    Text((CloseGuard.message(busy: window.busyTerminalTitles).map { $0 + "\n\n" } ?? "")
                         + "将关闭此窗口的所有页签并结束其中的终端会话，其他小窗不受影响。")
                }
                .alert("重命名小窗", isPresented: $renaming) {
                    TextField("窗口名称", text: $nameDraft).accessibilityLabel("窗口名称")
                    Button("取消", role: .cancel) {}
                    Button("保存") { window.rename(nameDraft) }
                        .disabled(MiniWindowSession.validatedName(nameDraft) == nil)
                } message: { Text("最多 32 个字") }
                ResourceCaption(usage: usage)
            }
            .opacity(snapshot.isVisible ? 1 : 0.42)
        }
    }
}

private let thumbnailHeight: CGFloat = 240

private struct WindowThumbnail: View {
    let width: CGFloat
    let image: NSImage?
    let highlighted: Bool
    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        ZStack {
            Color(nsColor: OrielPalette.surface)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        }
        .frame(width: width, height: thumbnailHeight)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.black.opacity(0.07), lineWidth: highlighted ? 0 : 0.5)
        }
        .overlay {
            shape.strokeBorder(OrielPalette.tint, lineWidth: 2).opacity(highlighted ? 1 : 0)
        }
        .shadow(color: .black.opacity(highlighted ? 0.16 : 0.08),
                radius: highlighted ? 12 : 8, x: 0, y: highlighted ? 5 : 3)
        .animation(.easeOut(duration: 0.14), value: highlighted)
    }
}

/// The small resource line under a thumbnail. Numbers use tabular digits so the
/// rows stay still while they update every two seconds.
private struct ResourceCaption: View {
    let usage: WindowResourceUsage

    var body: some View {
        HStack(spacing: 10) {
            if usage.isEmpty {
                Text("—")
            } else {
                metric("memorychip", usage.memoryText)
                metric("cpu", usage.cpuText)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(OrielPalette.mutedText)
        .lineLimit(1)
        .help(usage.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.isEmpty ? "没有单独统计的资源占用" : "内存 \(usage.memoryText)，CPU \(usage.cpuText)")
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(text)
        }
    }
}

struct ManagementEmptyView<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(OrielPalette.mutedText)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(OrielPalette.mutedText).multilineTextAlignment(.center)
            action().padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
