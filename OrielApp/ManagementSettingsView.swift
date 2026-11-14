import SwiftUI

struct ManagementSettingsView: View {
    @ObservedObject var settings: AppPreferences
    @ObservedObject var model: AppModel
    @State private var targetWindow: UUID?
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var notice: String?
    @State private var failed = false
    @State private var resetting = false
    private let labelWidth: CGFloat = 84

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Toggle("启动时打开主界面", isOn: $settings.openAtLaunch)
                    .toggleStyle(.checkbox).tint(OrielPalette.tint)

                group("新小窗默认值") {
                    labeled("尺寸") {
                        HStack(spacing: 6) {
                            TextField("宽", value: $settings.width, format: .number.precision(.fractionLength(0)))
                                .accessibilityLabel("默认宽度").multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder).frame(width: 62)
                            Text("×").foregroundStyle(OrielPalette.mutedText)
                            TextField("高", value: $settings.height, format: .number.precision(.fractionLength(0)))
                                .accessibilityLabel("默认高度").multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder).frame(width: 62)
                            Text("pt").foregroundStyle(OrielPalette.mutedText)
                            Spacer(minLength: 0)
                        }
                    }
                    labeled("背景") { opacitySlider($settings.backgroundOpacity, label: "背景") }
                    labeled("内容") { opacitySlider($settings.contentOpacity, label: "内容") }
                    if !model.windows.isEmpty {
                        labeled("目标小窗") {
                            Picker("目标小窗", selection: $targetWindow) {
                                Text("选择小窗").tag(nil as UUID?)
                                ForEach(model.windows) { window in Text(window.name).tag(Optional(window.id)) }
                            }
                            .labelsHidden().frame(maxWidth: 240)
                            .accessibilityLabel("应用默认设置的目标小窗")
                            Spacer(minLength: 0)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("应用到所选小窗") {
                            NSApp.mainWindow?.makeFirstResponder(nil)
                            guard let targetWindow, let window = model.windows.first(where: { $0.id == targetWindow }) else { return }
                            model.applyDefaults(to: targetWindow)
                            notice = "已应用到\(window.name)"; failed = false; exportURL = nil
                        }.disabled(!model.windows.contains { $0.id == targetWindow })
                        Button("恢复默认") { resetting = true }
                    }
                    .padding(.leading, labelWidth + 12)
                    Text("默认值用于新建小窗；左侧完全透明，右侧完全可见。")
                        .font(.system(size: 11)).foregroundStyle(OrielPalette.mutedText)
                        .padding(.leading, labelWidth + 12)
                }

                group("本地数据") {
                    Text("便签、书架、自选股和阅读进度保存在本机。")
                        .foregroundStyle(OrielPalette.mutedText)
                    HStack(spacing: 8) {
                        Button("导出数据…", action: chooseExport).disabled(exporting)
                        Button("打开数据目录") {
                            do {
                                try FileManager.default.createDirectory(at: model.dataDirectory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(model.dataDirectory)
                            } catch { failed = true; notice = error.localizedDescription; exportURL = nil }
                        }
                        if exporting { ProgressView().controlSize(.small); Text("正在导出…").foregroundStyle(OrielPalette.mutedText) }
                    }
                    Text("导出为独立副本，含废纸篓；暂不支持一键恢复。")
                        .font(.system(size: 11)).foregroundStyle(OrielPalette.mutedText)
                }

                if let notice {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed ? Color(nsColor: OrielPalette.amber) : OrielPalette.mutedText)
                        Text(notice).textSelection(.enabled)
                        if let exportURL { Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([exportURL]) } }
                        Spacer(minLength: 0)
                    }.font(.system(size: 11))
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .onChange(of: model.windows.map(\.id)) { _, ids in
            if let targetWindow, !ids.contains(targetWindow) { self.targetWindow = nil }
        }
        .alert("恢复默认设置？", isPresented: $resetting) {
            Button("取消", role: .cancel) {}
            Button("恢复") { settings.reset(); notice = "已恢复默认；现有小窗保持原样"; failed = false; exportURL = nil }
        } message: { Text("不影响便签、书架、自选股和现有小窗。") }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 11) { content() }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(OrielPalette.mutedText)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private func opacitySlider(_ value: Binding<Double>, label: String) -> some View {
        Slider(value: value, in: 0...1)
            .controlSize(.small)
            .tint(OrielPalette.tint)
            .frame(maxWidth: 240)
            .accessibilityLabel("默认\(label)透明度")
    }

    private func chooseExport() {
        guard let window = NSApp.mainWindow, !exporting else { return }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.prompt = "导出到此处"
        chooser.message = "将创建新的 Oriel 数据副本文件夹"
        chooser.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = chooser.url else { return }
            exporting = true; notice = nil; exportURL = nil
            Task {
                defer { exporting = false }
                do {
                    exportURL = try await model.exportData(to: destination)
                    failed = false; notice = "数据副本已导出"
                } catch { failed = true; notice = error.localizedDescription }
            }
        }
    }
}
