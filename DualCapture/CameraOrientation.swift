import AVFoundation
import UIKit

enum CameraOrientation {
    // 使用窗口方向，不使用会把横屏左右方向颠倒的 UIDeviceOrientation。
    static func videoOrientation(for orientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation? {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }
}
