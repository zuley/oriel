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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Toggle("启动时打开主界面", isOn: $settings.openAtLaunch).toggleStyle(.checkbox)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("新小窗默认值").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        Text("尺寸").frame(width: 70, alignment: .leading)
                        TextField("宽", value: $settings.width, format: .number.precision(.fractionLength(0)))
                            .accessibilityLabel("默认宽度").frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", value: $settings.height, format: .number.precision(.fractionLength(0)))
                            .accessibilityLabel("默认高度").frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("pt").foregroundStyle(.secondary)
                    }
                    opacityRow("背景", value: $settings.backgroundOpacity)
                    opacityRow("内容", value: $settings.contentOpacity)
                    if !model.windows.isEmpty {
                        Picker("目标小窗", selection: $targetWindow) {
                            Text("选择小窗").tag(nil as UUID?)
                            ForEach(model.windows) { window in Text(window.name).tag(Optional(window.id)) }
                        }.frame(maxWidth: 250).accessibilityLabel("应用默认设置的目标小窗")
                    }
                    HStack {
                        Button("应用到所选小窗") {
                            NSApp.mainWindow?.makeFirstResponder(nil)
                            guard let targetWindow, let window = model.windows.first(where: { $0.id == targetWindow }) else { return }
                            model.applyDefaults(to: targetWindow)
                            notice = "已应用到\(window.name)"; failed = false; exportURL = nil
                        }.disabled(!model.windows.contains { $0.id == targetWindow })
                        Button("恢复默认") { resetting = true }
                    }
                    Text("默认值用于新建小窗；左侧完全透明，右侧完全可见。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("本地数据").font(.system(size: 14, weight: .semibold))
                    Text("便签、书架、自选股和阅读进度保存在本机。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("导出数据…", action: chooseExport).disabled(exporting)
                        Button("打开数据目录") {
                            do {
                                try FileManager.default.createDirectory(at: model.dataDirectory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(model.dataDirectory)
                            } catch { failed = true; notice = error.localizedDescription; exportURL = nil }
                        }
                        if exporting { ProgressView().controlSize(.small); Text("正在导出…").foregroundStyle(.secondary) }
                    }
                    Text("导出为独立副本，含废纸篓；暂不支持一键恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let notice {
                    HStack(alignment: .top) {
                        Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(failed ? .orange : .secondary)
                        Text(notice).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if let exportURL { Button("查看") { NSWorkspace.shared.activateFileViewerSelecting([exportURL]) } }
                    }.font(.caption)
                }
            }.padding(.bottom, 8)
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

    private func opacityRow(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...1).accessibilityLabel("默认\(label)透明度").frame(maxWidth: 270)
        }
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
