import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal

enum PiPCorner: String, CaseIterable, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var next: PiPCorner {
        switch self {
        case .topTrailing:    return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        case .bottomLeading:  return .topLeading
        case .topLeading:     return .topTrailing
        }
    }
}

/// 小窗大小，按画面宽度取比例
enum PiPSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return String(localized: "小")
        case .medium: return String(localized: "中")
        case .large:  return String(localized: "大")
        }
    }
    var widthRatio: CGFloat {
        switch self {
        case .small:  return 0.24
        case .medium: return 0.30
        case .large:  return 0.38
        }
    }
}

/// 小窗宽高比。副画面按 aspect-fill 裁进这个框，不变形。
enum PiPAspect: String, CaseIterable, Identifiable {
    case portrait   // 9:16 竖
    case square     // 1:1
    case landscape  // 16:9 横

    var id: String { rawValue }
    var label: String {
        switch self {
        case .portrait:  return "9:16"
        case .square:    return "1:1"
        case .landscape: return "16:9"
        }
    }
    /// 高 / 宽
    var heightOverWidth: CGFloat {
        switch self {
        case .portrait:  return 16.0 / 9.0
        case .square:    return 1.0
        case .landscape: return 9.0 / 16.0
        }
    }
}

/// 把副画面缩成圆角小窗叠到主画面上，渲染成一张 CVPixelBuffer 供 AVAssetWriter 编码。
///
/// 只在**录制**时用。预览走两个独立的 AVCaptureVideoPreviewLayer（更省电、延迟更低），
/// 所以这里的几何参数必须和 UI 层的小窗保持一致，否则所见 ≠ 所录。
final class PiPCompositor {

    /// 小窗到画面边缘的留白，按画面宽度取比例
    static let marginRatio: CGFloat = 0.04
    /// 圆角占小窗宽度的比例
    static let radiusRatio: CGFloat = 0.09

    private let context: CIContext
    private var maskCache: (size: CGSize, radius: CGFloat, image: CIImage)?

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// 主画面铺满，副画面落在指定角落。渲染进 `output`。
    func compose(primary: CVPixelBuffer,
                 secondary: CVPixelBuffer?,
                 corner: PiPCorner,
                 size: PiPSize,
                 aspect: PiPAspect,
                 into output: CVPixelBuffer) {
        let base = CIImage(cvPixelBuffer: primary)

        guard let secondary else {
            // 副路还没出帧，先只写主画面，不要卡住录制
            context.render(base, to: output)
            return
        }

        let extent = base.extent
        let pipW = (extent.width * size.widthRatio).rounded()
        let pipH = (pipW * aspect.heightOverWidth).rounded()
        let margin = (extent.width * Self.marginRatio).rounded()

        // 注意：CIImage 坐标原点在左下角，和 UIKit 相反
        let origin: CGPoint
        switch corner {
        case .topLeading:
            origin = CGPoint(x: margin, y: extent.height - pipH - margin)
        case .topTrailing:
            origin = CGPoint(x: extent.width - pipW - margin, y: extent.height - pipH - margin)
        case .bottomLeading:
            origin = CGPoint(x: margin, y: margin)
        case .bottomTrailing:
            origin = CGPoint(x: extent.width - pipW - margin, y: margin)
        }

        let pipRect = CGRect(x: origin.x, y: origin.y, width: pipW, height: pipH)
        let inset = aspectFill(CIImage(cvPixelBuffer: secondary), into: pipRect)

        let radius = pipW * Self.radiusRatio
        let mask = roundedMask(size: pipRect.size, radius: radius)
            .transformed(by: CGAffineTransform(translationX: pipRect.minX, y: pipRect.minY))

        // CISourceInCompositing: 结果 = 源 ∩ 遮罩的不透明区域 → 得到圆角小窗
        let rounded = inset.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])

        context.render(rounded.composited(over: base), to: output)
    }

    // MARK: - 私有

    /// 等比放大到刚好盖住 rect，再居中裁到 rect，最后平移到位（不变形）
    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return image }

        let scale = max(rect.width / src.width, rect.height / src.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let s = scaled.extent
        let cropX = s.minX + (s.width - rect.width) / 2
        let cropY = s.minY + (s.height - rect.height) / 2
        let cropped = scaled.cropped(to: CGRect(x: cropX, y: cropY,
                                                width: rect.width, height: rect.height))

        return cropped.transformed(by: CGAffineTransform(translationX: rect.minX - cropX,
                                                         y: rect.minY - cropY))
    }

    /// 白色圆角矩形遮罩。尺寸不变时复用，避免每帧重建。
    private func roundedMask(size: CGSize, radius: CGFloat) -> CIImage {
        if let c = maskCache, c.size == size, c.radius == radius { return c.image }

        let f = CIFilter.roundedRectangleGenerator()
        f.extent = CGRect(origin: .zero, size: size)
        f.radius = Float(radius)
        f.color = CIColor.white

        let image = (f.outputImage ?? CIImage(color: .white))
            .cropped(to: CGRect(origin: .zero, size: size))
        maskCache = (size, radius, image)
        return image
    }
}
