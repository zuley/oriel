import Combine
import SwiftUI

struct ManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ManagementState
    private let accent = OrielPalette.tint

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if let url = Bundle.main.url(forResource: "OrielMark", withExtension: "pdf", subdirectory: "Brand"),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().frame(width: 30, height: 30)
                            .accessibilityHidden(true)
                    }
                    Text("Oriel").font(.system(size: 20, weight: .semibold))
                }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 12)
                ForEach(ManagementState.Section.allCases) { section in
                    Button { state.section = section } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 13, weight: section == state.section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 34)
                            .foregroundStyle(section == state.section ? accent : OrielPalette.text)
                            .background(section == state.section ? Color(nsColor: OrielPalette.selection) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(section == state.section ? .isSelected : [])
                }
                Spacer()
                Text("关闭主界面，小窗仍可用")
                    .font(.system(size: 10)).foregroundStyle(OrielPalette.mutedText).padding(.horizontal, 12).padding(.bottom, 14)
            }.padding(.horizontal, 8).frame(width: 164).background(Color(nsColor: OrielPalette.sidebar))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(state.section.rawValue).font(.system(size: 22, weight: .semibold))
                    Spacer()
                }
                Group {
                    switch state.section {
                    case .workspace: WorkspaceManagementView(model: model, isPresented: state.isPresented)
                    case .settings: ManagementSettingsView(settings: model.preferences, model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(24).background(Color(nsColor: OrielPalette.background))
        }
        .foregroundStyle(OrielPalette.text)
    }
}

private struct WorkspaceManagementView: View {
    @ObservedObject var model: AppModel
    let isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(model.windows.count) 个小窗").foregroundStyle(OrielPalette.mutedText)
                Spacer()
                Button { model.create() } label: { Label("新建小窗", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(OrielPalette.tint)
            }
            if model.windows.isEmpty {
                ManagementEmptyView(icon: "rectangle.on.rectangle", title: "还没有小窗", detail: "创建小窗后，在小窗中添加和使用内容。") { EmptyView() }
            } else {
                GeometryReader { viewport in
                    ScrollView([.vertical, .horizontal]) {
                        ThumbnailFlowLayout(spacing: 20, wrapWidth: viewport.size.width) {
                            ForEach(model.windows) { window in
                                ManagedWindowThumbnail(window: window, isPresented: isPresented,
                                                       viewportSize: viewport.size)
                                    .contentShape(Rectangle())
                                    .onHover { model.hoverWindow(window.id, inside: $0) }
                                    .onDisappear { model.hoverWindow(window.id, inside: false) }
                            }
                        }
                        .padding(.bottom, 8)
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height,
                               alignment: .topLeading)
                    }.coordinateSpace(name: "thumbnailViewport")
                }
            }
        }.font(.system(size: 12))
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
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var isInViewport = false
    @State private var closing = false
    @State private var renaming = false
    @State private var nameDraft = ""
    var body: some View {
        if let snapshot = window.snapshot {
            Button { window.showFromWorkspace() } label: {
                WindowThumbnail(windowSize: snapshot.frame.size, image: window.thumbnail)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(window.name)
            .accessibilityLabel(window.name)
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
        }
    }
}

private struct WindowThumbnail: View {
    let windowSize: CGSize
    let image: NSImage?
    private let height: CGFloat = 220

    private var width: CGFloat {
        height * max(windowSize.width, 1) / max(windowSize.height, 1)
    }

    var body: some View {
        ZStack {
            Color(nsColor: OrielPalette.surface)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: OrielPalette.divider), lineWidth: 1) }
    }
}

struct ManagementEmptyView<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(OrielPalette.mutedText)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(OrielPalette.mutedText).multilineTextAlignment(.center)
            action().padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
