import SwiftUI
import AVFoundation

/// 双摄小窗。仿微信视频通话：点一下主副互换，拖动吸附到最近的角。
///
/// 尺寸/留白/圆角全部复用 `PiPCompositor` 的比例常量——
/// 预览与录制合成必须共用同一套几何，否则所见 ≠ 所录。
struct PiPWindow: View {

    let previewLayer: AVCaptureVideoPreviewLayer
    @Binding var corner: PiPCorner
    /// 与录制合成共用同一组参数，否则所见 ≠ 所录
    let size: PiPSize
    let aspect: PiPAspect
    let container: CGSize
    /// 上方要避开的高度（提词面板）与下方要避开的高度（控制条）
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onSwap: () -> Void

    @State private var drag: CGSize = .zero

    private var pipSize: CGSize {
        let w = (container.width * size.widthRatio).rounded()
        return CGSize(width: w, height: (w * aspect.heightOverWidth).rounded())
    }
    private var margin: CGFloat { (container.width * PiPCompositor.marginRatio).rounded() }
    private var radius: CGFloat { pipSize.width * PiPCompositor.radiusRatio }

    var body: some View {
        let size = pipSize
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        CameraLayerView(previewLayer: previewLayer)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            .position(anchorCenter(for: corner, size: size))
            .offset(drag)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let base = anchorCenter(for: corner, size: size)
                        let dropped = CGPoint(x: base.x + value.translation.width,
                                              y: base.y + value.translation.height)
                        withAnimation(Theme.spring) {
                            corner = nearestCorner(to: dropped)
                            drag = .zero
                        }
                        Haptic.light()
                    }
            )
            .onTapGesture {
                Haptic.medium()
                onSwap()
            }
            .animation(Theme.spring, value: corner)
    }

    // MARK: 几何

    /// 小窗中心点。纵向被限制在提词面板与控制条之间的空当里。
    private func anchorCenter(for corner: PiPCorner, size: CGSize) -> CGPoint {
        let isLeading = (corner == .topLeading || corner == .bottomLeading)
        let isTop     = (corner == .topLeading || corner == .topTrailing)

        let x = isLeading
            ? margin + size.width / 2
            : container.width - margin - size.width / 2

        let minY = topInset + size.height / 2
        let maxY = container.height - bottomInset - size.height / 2
        let rawY = isTop ? minY : maxY

        return CGPoint(x: x, y: min(max(rawY, minY), max(minY, maxY)))
    }

    private func nearestCorner(to point: CGPoint) -> PiPCorner {
        let isLeading = point.x < container.width / 2
        let midY = (topInset + (container.height - bottomInset)) / 2
        let isTop = point.y < midY

        switch (isTop, isLeading) {
        case (true,  true):  return .topLeading
        case (true,  false): return .topTrailing
        case (false, true):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}
