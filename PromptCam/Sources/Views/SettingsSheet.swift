import SwiftUI

struct SettingsSheet: View {

    @Bindable var settings: PrompterSettings
    @Bindable var capture: CaptureController

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("提词器") {
                    slider("字号", value: $settings.fontSize,
                           range: PrompterSettings.fontSizeRange,
                           display: { "\(Int($0))" })

                    slider("行距", value: $settings.lineSpacing,
                           range: PrompterSettings.lineSpacingRange,
                           display: { "\(Int($0))" })

                    slider("面板高度", value: $settings.heightRatio,
                           range: PrompterSettings.heightRange,
                           display: { "\(Int($0 * 100))%" })

                    slider("背景暗度", value: $settings.dimOpacity,
                           range: PrompterSettings.dimRange,
                           display: { "\(Int($0 * 100))%" })

                    slider("阅读线位置", value: $settings.readingLine,
                           range: PrompterSettings.readingLineRange,
                           display: { "\(Int($0 * 100))%" })
                }

                Section {
                    Toggle("跟读自动滚动", isOn: $settings.autoScroll)
                        .tint(Theme.accent)
                } header: {
                    Text("跟读")
                } footer: {
                    Text("关掉后就是普通提词器,需要手动划动稿子。")
                }

                Section {
                    Picker("小窗大小", selection: $capture.pipSize) {
                        ForEach(PiPSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("小窗比例", selection: $capture.pipAspect) {
                        ForEach(PiPAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("双摄小窗")
                } footer: {
                    Text("小窗位置直接拖动画面上的小窗即可,会吸附到最近的角;点一下小窗前后互换。")
                }

                Section {
                    Toggle("稿子左右翻转", isOn: $settings.mirrored)
                        .tint(Theme.accent)
                    Toggle("前置录制镜像", isOn: $capture.mirrorFrontOutput)
                        .tint(Theme.accent)
                        .onChange(of: capture.mirrorFrontOutput) { _, _ in
                            capture.refreshMirroring()
                        }
                } header: {
                    Text("拍摄")
                } footer: {
                    Text("「稿子左右翻转」给外接分光提词器用。\n「前置录制镜像」关掉后,录出来的画面和别人看你时一致(画面里有文字时建议关)。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgBase)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .tint(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func slider(_ label: LocalizedStringKey,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundStyle(Theme.fg)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.fgMuted)
            }
            Slider(value: value, in: range)
                .tint(Theme.accent)
        }
        .padding(.vertical, 2)
    }
}
