import SwiftUI
import UIKit

/// 视觉规范：visual-router #71 Modern Dark (Cinema Mobile)
///
/// 针对相机场景做了两处刻意偏离，理由见 docs/技术方案.md：
/// 1. 不实现原风格的 ambient blob 动态光斑（相机画面本身在动，再加光斑是干扰）
/// 2. 字体用系统 SF Pro 而非 Inter（中文回退苹方 PingFang SC，屏显最佳）
enum Theme {

    // MARK: 背景（原风格明令避免纯 #000000，OLED 拖影）
    static let bgDeep     = Color(hex: 0x020203)
    static let bgBase     = Color(hex: 0x050506)
    static let bgElevated = Color(hex: 0x0A0A0C)

    // MARK: 前景
    static let fg      = Color(hex: 0xEDEDEF)
    static let fgMuted = Color(hex: 0x8A8F98)

    // MARK: 强调
    static let accent     = Color(hex: 0x5E6AD2)
    static let accentGlow = Color(hex: 0x5E6AD2).opacity(0.20)

    /// 脱稿模式提示色（琥珀）
    static let warn = Color(hex: 0xE8A33D)
    /// 录制态
    static let rec  = Color(hex: 0xFF453A)

    // MARK: 描边与表面（一律 rgba，不用实色灰）
    static let border  = Color.white.opacity(0.08)
    static let surface = Color.white.opacity(0.05)

    static let radius: CGFloat = 16

    /// 提词文本三态。
    ///
    /// 用**实色**而不是同一个白色配不同 opacity —— 半透明白叠在毛玻璃和
    /// 变化的相机画面上，38% 和 70% 根本分不出来（实测教训）。
    enum ReadState {
        static let read    = Color(hex: 0x71717A)   // 已读：中性灰，明显退到背景
        static let current = Color(hex: 0xFFFFFF)   // 当前字：纯白 + 靛蓝底
        static let unread  = Color(hex: 0xF4F4F6)   // 未读：接近纯白
        /// 当前字的背景块，让落点一眼可见
        static let currentBackground = Theme.accent
    }

    /// 原风格指定 easing：cubic-bezier(0.16, 1, 0.3, 1)
    static func ease(_ duration: Double = 0.35) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: duration)
    }

    /// 弹性（模态、控件按压）
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:     Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >>  8) & 0xFF) / 255,
            blue:    Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - 触觉

enum Haptic {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
