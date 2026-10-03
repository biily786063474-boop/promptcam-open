import SwiftUI
import AVFoundation

/// 把一个 `AVCaptureVideoPreviewLayer` 挂到 SwiftUI 里。
///
/// 双摄的主副互换就是把两个 layer 在全屏位与小窗位之间对调，
/// 不重建任何 connection，所以是瞬时的、无黑屏。
struct CameraLayerView: UIViewRepresentable {

    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.backgroundColor = .black
        v.attach(previewLayer)
        return v
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.attach(previewLayer)
    }

    final class LayerHostView: UIView {
        private weak var hosted: AVCaptureVideoPreviewLayer?

        func attach(_ incoming: AVCaptureVideoPreviewLayer) {
            guard hosted !== incoming else { return }
            // 只摘自己身上的那层。互换时对方可能已经接管了它，
            // 无条件 removeFromSuperlayer 会把刚挂好的层误摘掉。
            if let old = hosted, old.superlayer === layer {
                old.removeFromSuperlayer()
            }
            hosted = incoming
            layer.addSublayer(incoming)     // 自动从旧 superlayer 迁出
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 关掉隐式动画，否则旋转/换位时会有一帧拉伸
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
