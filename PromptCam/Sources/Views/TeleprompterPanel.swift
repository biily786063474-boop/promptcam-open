import SwiftUI
import UIKit

/// 悬浮提词面板。
///
/// 逐字高亮 + 逐行滚动：文本按视觉行切开（CoreText 算的），每行单独渲染，
/// 读到哪个字就在那个字上分色。滚动目标是"当前字所在的那一行"，
/// 所以读完一行才滚一行，不会因为一句话跨多行而整段跳。
///
/// 层次（由内到外）：文本 → 黑色暗底 → Liquid Glass → 描边。
/// 玻璃负责"能透出构图"，暗底负责"字还看得清"。
struct TeleprompterPanel: View {

    let script: ParsedScript
    /// 已读到的字符位置（utf16 偏移），由对齐算法驱动
    let readOffset: Int
    /// 脱稿状态：边框转琥珀，提示"没跟上你了"
    let isOffScript: Bool
    /// 点某行手动跳过去 —— 跟读跑偏时把锚点拉回来
    let onTapOffset: (Int) -> Void
    /// 整屏高度，由父视图的 GeometryReader 提供
    let screenHeight: CGFloat

    @Bindable var settings: PrompterSettings

    @State private var dragDelta: CGFloat = 0
    @State private var layout: PrompterLayout = .empty
    /// 上次算 layout 用的输入，变了才重算（CoreText 排版不便宜）
    @State private var layoutKey: LayoutKey?

    /// 把手连同上下留白占 26pt，父视图按 panelHeight + 26 预留
    static let handleHeight: CGFloat = 26

    private struct LayoutKey: Equatable {
        let text: String
        let fontSize: Double
        let width: CGFloat
    }

    private var panelHeight: CGFloat { clampedHeight(screenHeight) }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
    }

    private var font: UIFont {
        .systemFont(ofSize: settings.fontSize, weight: .regular)
    }

    /// 当前字所在行
    private var currentLine: Int {
        layout.lineIndex(containing: readOffset)
    }

    var body: some View {
        VStack(spacing: 0) {
            textArea
            handle
        }
    }

    // MARK: 文本区

    private var textArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: settings.lineSpacing) {
                        // 上下留白，保证首行/末行也能停到阅读线上
                        Color.clear.frame(height: panelHeight * settings.readingLine)

                        ForEach(layout.lines) { line in
                            lineView(line)
                                .id(line.id)
                        }

                        Color.clear.frame(height: panelHeight * (1 - settings.readingLine))
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentLine) { _, line in
                    guard settings.autoScroll else { return }
                    // 短促：滚动动画长了会让人觉得"字已经念过去了、稿子还在挪"
                    withAnimation(Theme.ease(0.18)) {
                        proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: settings.readingLine))
                    }
                }
                // 上下边缘渐隐。逐行滚动时行高不整除面板高，上缘必然停在半行上，
                // 硬切看着像渲染坏了；渐隐让它自然淡出（专业提词器都这么做）。
                .mask(edgeFade)
            }
            .task(id: LayoutKey(text: script.displayText,
                                fontSize: settings.fontSize,
                                width: geo.size.width - horizontalPadding * 2)) {
                recomputeLayout(width: geo.size.width - horizontalPadding * 2)
            }
        }
        .frame(height: panelHeight)
        // 暗底必须跟随圆角，否则四角会在玻璃外露出直角黑边
        .background(panelShape.fill(Color.black.opacity(settings.dimOpacity)))
        .clipShape(panelShape)
        .glassEffect(.regular, in: panelShape)
        .overlay {
            panelShape.strokeBorder(isOffScript ? Theme.warn : Theme.border,
                                    lineWidth: isOffScript ? 1.5 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isOffScript { offScriptTag }
        }
        // 外接分光提词器：左右翻转
        .scaleEffect(x: settings.mirrored ? -1 : 1, y: 1, anchor: .center)
        .padding(.horizontal, 12)
        .animation(Theme.ease(0.3), value: isOffScript)
    }

    private var horizontalPadding: CGFloat { 18 }

    /// 渐隐带占面板高的 13% —— 约 0.6 行，刚好吃掉被切的半行，
    /// 再宽就开始啃可读区（面板本来只放得下 5 行左右）。
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.13),
                .init(color: .black, location: 0.87),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 一行：已读段 / 当前字 / 未读段 三段分色。
    /// 切分全程用 NSString（utf16），和 CoreText 给的行区间同一口径。
    private func lineView(_ line: PrompterLayout.Line) -> some View {
        let ns = script.displayText as NSString
        let lineLength = min(line.range.count, max(0, ns.length - line.range.lowerBound))
        let lineText = ns.substring(with: NSRange(location: line.range.lowerBound,
                                                 length: lineLength)) as NSString

        // 该行内已读了多少个 utf16 单元
        let localRead = min(max(readOffset - line.range.lowerBound, 0), lineText.length)

        // 光标是否真的落在这一行。
        // 少了这一步，未读行的 readOffset - lowerBound 是负数、被夹成 0，
        // localRead < length 照样成立，于是每个未读行的首字都被当成"当前字"
        // 套上靛蓝底 —— 满屏行首都在高亮。
        let holdsCursor = readOffset >= line.range.lowerBound
            && readOffset < line.range.lowerBound + lineText.length

        // 当前字单独取出来加重，视线容易找到落点。
        // 用 composed character sequence，避免把一个字形切成两半。
        let currentLen = holdsCursor
            ? lineText.rangeOfComposedCharacterSequence(at: localRead).length
            : 0

        var read = AttributedString(lineText.substring(to: localRead))
        read.foregroundColor = Theme.ReadState.read

        var current = AttributedString(
            lineText.substring(with: NSRange(location: localRead, length: currentLen))
        )
        current.foregroundColor = Theme.ReadState.current
        current.backgroundColor = Theme.ReadState.currentBackground
        current.font = .system(size: settings.fontSize, weight: .semibold)

        var rest = AttributedString(lineText.substring(from: localRead + currentLen))
        rest.foregroundColor = Theme.ReadState.unread

        return Text(read + current + rest)
            .font(.system(size: settings.fontSize))
            .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.light()
            onTapOffset(line.range.lowerBound)
        }
    }

    private var offScriptTag: some View {
        Text("脱稿中")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.warn.opacity(0.14)))
            .padding(10)
    }

    // MARK: 布局

    private func recomputeLayout(width: CGFloat) {
        let key = LayoutKey(text: script.displayText,
                            fontSize: settings.fontSize,
                            width: width)
        guard key != layoutKey else { return }
        layout = PrompterLayout.compute(text: script.displayText, font: font, width: width)
        layoutKey = key
    }

    // MARK: 高度把手

    private var handle: some View {
        Capsule()
            .fill(Theme.fgMuted.opacity(0.55))
            .frame(width: 44, height: 5)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)          // 扩大命中区
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { dragDelta = $0.translation.height }
                    .onEnded { _ in
                        settings.heightRatio = clampedRatio(
                            settings.heightRatio + dragDelta / screenHeight
                        )
                        dragDelta = 0
                        Haptic.light()
                    }
            )
    }

    // MARK: 尺寸

    private func clampedHeight(_ screenH: CGFloat) -> CGFloat {
        screenH * clampedRatio(settings.heightRatio + dragDelta / screenH)
    }

    private func clampedRatio(_ r: Double) -> Double {
        min(max(r, PrompterSettings.heightRange.lowerBound),
            PrompterSettings.heightRange.upperBound)
    }
}
