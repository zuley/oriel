import SwiftUI

struct ManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ManagementState
    private let accent = Color(red: 0.19, green: 0.37, blue: 0.34)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Oriel").font(.system(size: 20, weight: .semibold)).padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 18)
                ForEach(ManagementState.Section.allCases) { section in
                    Button { state.section = section } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 13, weight: section == state.section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 34)
                            .foregroundStyle(section == state.section ? accent : .primary)
                            .background(section == state.section ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityAddTraits(section == state.section ? .isSelected : [])
                }
                Spacer()
                Text("关闭主界面，小窗仍可用")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 14)
            }.padding(.horizontal, 8).frame(width: 164).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(state.section.rawValue).font(.system(size: 22, weight: .semibold))
                    Spacer()
                }
                Group {
                    switch state.section {
                    case .workspace: WorkspaceManagementView(model: model)
                    case .settings: ManagementSettingsView(settings: model.preferences, model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(24).background(Color(nsColor: .controlBackgroundColor))
        }
        .tint(accent)
    }
}

private struct WorkspaceManagementView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(model.windows.count) 个小窗").foregroundStyle(.secondary)
                Spacer()
                Button { model.create() } label: { Label("新建小窗", systemImage: "plus") }
            }
            if model.windows.isEmpty {
                ManagementEmptyView(icon: "rectangle.on.rectangle", title: "还没有小窗", detail: "创建小窗后，在小窗中添加和使用内容。") { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.windows) { window in
                            ManagedWindowRow(window: window)
                                .contentShape(Rectangle())
                                .onHover { model.hoverWindow(window.id, inside: $0) }
                                .onDisappear { model.hoverWindow(window.id, inside: false) }
                            Divider()
                        }
                    }
                }
            }
        }.font(.system(size: 12))
            .onDisappear { model.clearWindowHover() }
    }
}

private struct ManagedWindowRow: View {
    @ObservedObject var window: MiniWindowSession
    @State private var closing = false
    @State private var renaming = false
    @State private var nameDraft = ""
    var body: some View {
        if let snapshot = window.snapshot {
            HStack(spacing: 12) {
                Image(systemName: "macwindow").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(window.name).font(.system(size: 14, weight: .medium))
                            .lineLimit(1).truncationMode(.tail).help(window.name)
                        Button {
                            nameDraft = window.name
                            renaming = true
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("重命名")
                            .accessibilityLabel("重命名 \(window.name)")
                    }
                    HStack(spacing: 6) {
                        Circle().fill(snapshot.isVisible ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(snapshot.isVisible ? "已显示" : "已隐藏").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(snapshot.isVisible ? "隐藏" : "显示") {
                    if snapshot.isVisible { window.hide() }
                    else if window.needsTransparencyRecovery { window.findWindow() }
                    else { window.recover() }
                }.accessibilityLabel("\(snapshot.isVisible ? "隐藏" : "显示") \(window.name)")
                Button("关闭") { closing = true }.accessibilityLabel("关闭 \(window.name)")
            }.padding(.vertical, 16)
            .alert("关闭\(window.name)？", isPresented: $closing) {
                Button("取消", role: .cancel) {}
                Button("关闭", role: .destructive) { window.close() }
            } message: { Text("将关闭此窗口的所有页签并结束其中的终端会话，其他小窗不受影响。") }
            .alert("重命名小窗", isPresented: $renaming) {
                TextField("窗口名称", text: $nameDraft).accessibilityLabel("窗口名称")
                Button("取消", role: .cancel) {}
                Button("保存") { window.rename(nameDraft) }
                    .disabled(MiniWindowSession.validatedName(nameDraft) == nil)
            } message: { Text("最多 32 个字") }
        }
    }
}

struct ManagementEmptyView<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action().padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
