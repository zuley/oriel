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
    @State private var showCustom = false
    private let labelWidth: CGFloat = 84

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Toggle("启动时打开主界面", isOn: $settings.openAtLaunch)
                    .toggleStyle(.checkbox).tint(OrielPalette.tint)

                group("新小窗默认值") {
                    presetPicker
                    if let preset = settings.currentPreset {
                        Text(preset.summary).font(.system(size: 10))
                            .foregroundStyle(OrielPalette.mutedText).padding(.leading, 2)
                    } else {
                        Text("当前为自定义值").font(.system(size: 10))
                            .foregroundStyle(OrielPalette.mutedText).padding(.leading, 2)
                    }
                    if showCustom { customFields }
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
                    Text("选择预设用于新建小窗；自定义可单独调整尺寸与透明度。")
                        .font(.system(size: 11)).foregroundStyle(OrielPalette.mutedText)
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
        .onAppear { if settings.currentPreset == nil { showCustom = true } }
        .onChange(of: settings.currentPreset?.id) { _, id in
            if id == nil { showCustom = true }
        }
        .onChange(of: model.windows.map(\.id)) { _, ids in
            if let targetWindow, !ids.contains(targetWindow) { self.targetWindow = nil }
        }
        .alert("恢复默认设置？", isPresented: $resetting) {
            Button("取消", role: .cancel) {}
            Button("恢复") {
                settings.reset(); showCustom = false
                notice = "已恢复默认；现有小窗保持原样"; failed = false; exportURL = nil
            }
        } message: { Text("不影响便签、书架、自选股和现有小窗。") }
    }

    /// A compact segmented row: three shape presets plus a custom cell, each with an
    /// icon above its name. Custom toggles the size fields and opacity sliders.
    private var presetPicker: some View {
        let custom = showCustom || settings.currentPreset == nil
        return HStack(spacing: 3) {
            ForEach(WindowPreset.all) { preset in
                let selected = !custom && settings.currentPreset?.id == preset.id
                Button {
                    settings.apply(preset)
                    showCustom = false
                } label: {
                    cell(icon: PresetGlyph(preset: preset, selected: selected),
                         title: preset.title, selected: selected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityValue(preset.summary)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(preset.title) · \(preset.summary)")
            }
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showCustom.toggle() }
            } label: {
                cell(icon: Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(custom ? OrielPalette.tint : OrielPalette.mutedText)
                        .frame(width: 30, height: 28),
                     title: "自定义", selected: custom)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("自定义尺寸与透明度")
            .accessibilityAddTraits(custom ? .isSelected : [])
            .help("自定义尺寸与透明度")
        }
        .padding(3)
        .background(Color(nsColor: OrielPalette.field), in: RoundedRectangle(cornerRadius: 7))
    }

    private func cell<Icon: View>(icon: Icon, title: String, selected: Bool) -> some View {
        VStack(spacing: 4) {
            icon
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? OrielPalette.tint : OrielPalette.text)
        }
        .frame(width: 62, height: 48)
        .background(selected ? Color(nsColor: OrielPalette.surface) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    /// The original controls stay available for values outside the presets.
    private var customFields: some View {
        VStack(alignment: .leading, spacing: 11) {
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
        }
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

/// A window silhouette drawn at the preset's real aspect ratio, so tall, wide and
/// square read at a glance. All three fit the same 26 pt box.
private struct PresetGlyph: View {
    let preset: WindowPreset
    let selected: Bool
    private let side: CGFloat = 26

    private var box: CGSize {
        let scale = min(side / preset.width, side / preset.height)
        return CGSize(width: preset.width * scale, height: preset.height * scale)
    }

    var body: some View {
        let stroke: Color = selected ? OrielPalette.tint : OrielPalette.mutedText.opacity(0.65)
        return ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(selected ? OrielPalette.tint.opacity(0.09) : .clear)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1)
            // A title bar and one body rule make the shape read as a small window.
            VStack(spacing: 2) {
                Rectangle().fill(stroke.opacity(0.65)).frame(height: 2.5)
                Rectangle().fill(stroke.opacity(0.3)).frame(height: 1)
                    .padding(.horizontal, 2.5)
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
        }
        .frame(width: box.width, height: box.height)
        .frame(width: 30, height: 28)
        .accessibilityHidden(true)
    }
}
