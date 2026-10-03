import Foundation

/// 单摄 / 前后双摄画中画，均由 CaptureController 管理。
enum ShootingMode: String, CaseIterable, Identifiable {
    case single
    case dual

    var id: String { rawValue }

    var captureMode: CaptureMode {
        switch self {
        case .single: return .single
        case .dual: return .dual
        }
    }
}
