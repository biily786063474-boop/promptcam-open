import SwiftUI

/// 底部控制条。#71 Modern Dark：GlassEffectContainer + 圆形玻璃按钮。
/// 触摸目标 ≥ 56pt，单手可及。
struct RecordControls: View {

    let isRecording: Bool
    /// 单摄录制中要禁用（切镜头会重建 session 断流）；
    /// 双摄的主副互换只是换合成主路，录制中也安全。
    let canFlip: Bool
    let flipIcon: String
    var canStartRecording: Bool = true
    /// 最近一条录制的首帧，没有则显示占位图标
    let libraryThumbnail: UIImage?
    let onToggleRecord: () -> Void
    let onFlip: () -> Void
    let onOpenLibrary: () -> Void

    private var recordButtonEnabled: Bool { isRecording || canStartRecording }

    // 布局照系统相机的肌肉记忆走：左回看、中快门、右翻转。
    // 脚本入口不放这儿——顶部常驻工具条已经有了，重复摆会挤掉触摸目标。
    var body: some View {
        GlassEffectContainer(spacing: 22) {
            HStack(spacing: 34) {
                LibraryButton(image: libraryThumbnail, action: onOpenLibrary)
                    .disabled(isRecording)
                    .opacity(isRecording ? 0.35 : 1)

                RecordButton(isRecording: isRecording, action: onToggleRecord)
                    .disabled(!recordButtonEnabled)
                    .opacity(recordButtonEnabled ? 1 : 0.35)

                GlassCircleButton(system: flipIcon, action: onFlip)
                    .disabled(!canFlip)
                    .opacity(canFlip ? 1 : 0.35)
            }
        }
        .animation(Theme.ease(0.25), value: isRecording)
        .animation(Theme.ease(0.25), value: canFlip)
        .animation(Theme.ease(0.25), value: recordButtonEnabled)
    }
}

// MARK: - 录制按钮

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.medium()
            action()
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.fg.opacity(0.9), lineWidth: 4)
                    .frame(width: 76, height: 76)

                RoundedRectangle(cornerRadius: isRecording ? 7 : 30, style: .continuous)
                    .fill(Theme.rec)
                    .frame(width: isRecording ? 30 : 60,
                           height: isRecording ? 30 : 60)
            }
            .frame(width: 84, height: 84)          // 触摸目标
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .animation(Theme.spring, value: isRecording)
        .accessibilityLabel(isRecording ? "停止录制" : "开始录制")
    }
}

// MARK: - 回看按钮

private struct LibraryButton: View {
    let image: UIImage?
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.light()
            action()
        } label: {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        }
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .frame(width: 56, height: 56)        // 触摸目标
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("回看录制")
    }
}

// MARK: - 圆形玻璃按钮

struct GlassCircleButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.light()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Theme.fg)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - 按压反馈（原风格：scale 0.97）

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.ease(0.18), value: configuration.isPressed)
    }
}
