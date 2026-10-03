import SwiftUI
import UIKit

/// 屏幕边缘柔光补光灯。
///
/// 原理就是拿屏幕当补光板：把四边画成一圈柔光带，靠背光照亮面部。
/// 所以真正决定补光量的是**屏幕亮度**，不是这层光带画得多白 ——
/// 开灯时必须把亮度顶满（见 `ScreenBrightness`）。
///
/// 层级上必须夹在摄像头预览之上、提词面板之下：压在提词器上面会把字糊掉。
/// 它是屏幕上的 UI，摄像头的像素流里没有它，所以录不进成片
/// （录制帧来自 AVCaptureVideoDataOutput，见 `CaptureController.captureOutput`）。
struct RingLight: View {

    /// 光带不透明度
    let level: Double
    /// 0 冷白 → 1 暖白
    let warmth: Double
    /// 光带宽度占屏幕短边的比例
    let width: Double

    var body: some View {
        GeometryReader { geo in
            // 以短边为基准，横竖屏下光带宽度观感一致
            let unit = min(geo.size.width, geo.size.height) * width

            ZStack {
                // 外层大范围光晕：负责"柔"，避免出现一条硬边亮带
                band(width: unit * 1.9, blur: unit * 0.90, opacity: level * 0.45)
                // 中层：主要光量
                band(width: unit * 0.95, blur: unit * 0.30, opacity: level * 0.80)
                // 实心核：几乎不模糊。blur 半径接近光带宽度时峰值会被摊掉一半，
                // 屏幕像素到不了纯白就照不亮脸 —— 这一层专门保住峰值。
                band(width: unit * 0.40, blur: unit * 0.05, opacity: level)
            }
        }
        .ignoresSafeArea()
        // 不能吃掉手势 —— 底下还有提词器点击跳转和小窗拖动
        .allowsHitTesting(false)
    }

    private func band(width: CGFloat, blur: CGFloat, opacity: Double) -> some View {
        Rectangle()
            .strokeBorder(lightColor.opacity(opacity), lineWidth: width)
            .blur(radius: blur)
            // 相加而不是相盖：三层重叠处才能突破单层不透明度的上限，
            // 也让底下的画面跟着提亮 —— 真实环形灯就是这个观感。
            .blendMode(.plusLighter)
    }

    /// 冷白到暖白线性插值，中点接近纯白
    private var lightColor: Color {
        let t = min(max(warmth, 0), 1)
        return Color(
            red:   0.90 + (1.00 - 0.90) * t,
            green: 0.945 + (0.925 - 0.945) * t,
            blue:  1.00 + (0.82 - 1.00) * t
        )
    }
}

// MARK: - 悬浮调节面板

/// 补光灯的悬浮控制面板。
///
/// 参数只在这里调，设置页不再重复放一份 —— 同一组值两个入口，
/// 改一处忘一处是迟早的事。
struct LightPanel: View {

    @Bindable var settings: PrompterSettings
    let onClose: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            Group {
                slider("亮度", value: $settings.fillLightLevel,
                       range: PrompterSettings.fillLightRange,
                       display: { "\(Int($0 * 100))%" })

                slider("色温", value: $settings.fillLightWarmth,
                       range: 0...1,
                       display: warmthLabel)

                slider("边缘", value: $settings.fillLightWidth,
                       range: PrompterSettings.fillWidthRange,
                       display: { "\(Int($0 * 100))%" })
            }
            // 灯关着还能拖滑杆会让人以为没生效
            .disabled(!settings.fillLight)
            .opacity(settings.fillLight ? 1 : 0.35)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // 面板自己也在补光范围内，底色不压暗的话滑杆会糊在光里
        .background(shape.fill(Color.black.opacity(0.55)))
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(Theme.border, lineWidth: 1) }
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(settings.fillLight ? Theme.accent : Theme.fgMuted)

            Text("补光灯")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.fg)

            Spacer()

            Toggle("", isOn: $settings.fillLight)
                .labelsHidden()
                .tint(Theme.accent)

            Button {
                Haptic.light()
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fgMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }

    /// 色温给"冷白/中性/暖白"而不是开尔文数字 —— 用户要的是脸的观感，
    /// 暖白显肤色好，冷白更接近日光、白衬衫不发黄。
    private func warmthLabel(_ v: Double) -> String {
        if v < 0.34 { return String(localized: "冷白") }
        if v < 0.67 { return String(localized: "中性") }
        return String(localized: "暖白")
    }

    private func slider(_ label: LocalizedStringKey,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.fgMuted)
            }
            Slider(value: value, in: range)
                .tint(Theme.accent)
        }
    }
}

// MARK: - 屏幕亮度

/// 开补光灯时把屏幕亮度顶满，关灯/退到后台时还回去。
///
/// 只在第一次 boost 时记原值：连续 boost 不会把"1.0"当成用户原来的亮度存下来，
/// 否则关灯后亮度就永久卡在满格了。
enum ScreenBrightness {

    private static var saved: CGFloat?

    static func boost() {
        guard saved == nil, let screen = currentScreen else { return }
        saved = screen.brightness
        screen.brightness = 1.0
    }

    static func restore() {
        guard let value = saved, let screen = currentScreen else { return }
        screen.brightness = value
        saved = nil
    }

    private static var currentScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
    }
}
