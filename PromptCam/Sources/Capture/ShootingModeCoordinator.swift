import Foundation
import Observation

/// 单摄 / 双摄切换与录制路由。
@MainActor
@Observable
final class ShootingModeCoordinator {
    @ObservationIgnored private let capture: CaptureController

    init(capture: CaptureController) {
        self.capture = capture
    }

    // 读取实际模式，不另存影子状态，确保硬件不足退回单摄时 UI 同步。
    var mode: ShootingMode { capture.mode == .dual ? .dual : .single }
    var isRecording: Bool { capture.recording.isRecording }
    var recordedDuration: TimeInterval { capture.recording.recordedDuration }
    var canStartRecording: Bool { true }

    func switchTo(_ target: ShootingMode) {
        guard target != mode, !isRecording else { return }
        if target == .dual, !capture.isDualSupported { return }
        // configure 在同一串行采集队列内完成停旧建新，不额外 stop/start。
        capture.configure(mode: target.captureMode)
    }

    func toggleRecording() {
        isRecording ? capture.stopRecording() : capture.startRecording()
    }
}
