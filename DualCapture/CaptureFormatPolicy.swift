import Foundation

struct CaptureFormatCandidate {
    let id: Int
    let dimensions: CGSize
    let horizontalFieldOfView: Double
    let supportsMultiCam: Bool
    let supports30FPS: Bool
    let isBinned: Bool

    var pixelCount: CGFloat { dimensions.width * dimensions.height }

    /// 水平方向视角由系统提供，按短边所占比例换算最大内切圆的直径视角。
    var circularFieldOfView: Double {
        guard dimensions.width > 0, dimensions.height > 0,
              horizontalFieldOfView > 0, horizontalFieldOfView < 180 else { return 0 }
        let ratio = Double(min(dimensions.width, dimensions.height) / dimensions.width)
        let tangent = tan(horizontalFieldOfView * .pi / 360) * ratio
        return atan(tangent) * 360 / .pi
    }
}

enum CaptureFormatPolicy {
    static func ranked(_ formats: [CaptureFormatCandidate]) -> [CaptureFormatCandidate] {
        let supported = formats.filter {
            $0.supportsMultiCam && $0.supports30FPS && $0.dimensions.width.isFinite && $0.dimensions.height.isFinite && $0.dimensions.width > 0 && $0.dimensions.height > 0
        }
        // 只处理双摄预览与合成所需的分辨率，避免为了视野而直接启用双路 4K。
        let bounded = supported.filter { max($0.dimensions.width, $0.dimensions.height) <= 1920 && min($0.dimensions.width, $0.dimensions.height) <= 1440 }
        return bounded.sorted {
            let firstField = ($0.circularFieldOfView * 1000).rounded()
            let secondField = ($1.circularFieldOfView * 1000).rounded()
            if firstField != secondField {
                return firstField > secondField
            }
            if $0.isBinned != $1.isBinned { return $0.isBinned }
            if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
            return $0.id < $1.id
        }
    }

    static func lowerCostCandidate(than current: CaptureFormatCandidate, from formats: [CaptureFormatCandidate]) -> CaptureFormatCandidate? {
        ranked(formats.filter {
            $0.pixelCount < current.pixelCount || ($0.pixelCount == current.pixelCount && $0.isBinned && !current.isBinned)
        }).first
    }
}

enum CameraFrameGeometry {
    /// 圆的直径等于原始帧短边，且居中；超过这个直径就需要补边或拉伸。
    static func largestCircleBounds(in source: CGRect) -> CGRect {
        let diameter = min(source.width, source.height)
        return CGRect(x: source.midX - diameter / 2, y: source.midY - diameter / 2, width: diameter, height: diameter)
    }
}
