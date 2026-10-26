import Foundation

enum PictureInPictureMetrics {
    static let widthRatio: CGFloat = 0.28
    static let heightRatio: CGFloat = 0.20
    static let leftMarginRatio: CGFloat = 0.05
    static let topMarginRatio: CGFloat = 0.10
}

enum VideoLayoutFrames {
    static func splitFrames(in renderSize: CGSize) -> (top: CGRect, bottom: CGRect) {
        let halfHeight = renderSize.height / 2
        return (
            top: CGRect(x: 0, y: 0, width: renderSize.width, height: halfHeight),
            bottom: CGRect(x: 0, y: halfHeight, width: renderSize.width, height: halfHeight)
        )
    }
}

enum CameraSide: Equatable {
    case front
    case rear

    var secondary: CameraSide { self == .front ? .rear : .front }
}

enum CaptureLayout: String, CaseIterable, Identifiable {
    case pictureInPicture
    case split
    case sideBySide
    case fullScreen

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pictureInPicture: return "画中画"
        case .split: return "上下"
        case .sideBySide: return "左右"
        case .fullScreen: return "全屏"
        }
    }
}

enum SmallWindowShape: String, CaseIterable, Identifiable {
    case roundedRectangle
    case circle
    var id: String { rawValue }
    var title: String { self == .circle ? "圆形" : "圆角长方形" }
}

struct PictureInPictureSettings: Equatable {
    var shape: SmallWindowShape = .roundedRectangle
    var scale: Double = 1
    var center = CGPoint(x: 0.19, y: 0.20)

    func frame(in size: CGSize) -> CGRect {
        let factor = CGFloat(min(max(scale.isFinite ? scale : 1, 0.6), 1.8))
        let desiredWidth = size.width * PictureInPictureMetrics.widthRatio * factor
        let desiredHeight = shape == .circle ? desiredWidth : size.height * PictureInPictureMetrics.heightRatio * factor
        // 展开、横屏及小窗口中以短边限制整体大小，圆形不能超出窗口或变成椭圆。
        let fit = min(1, size.width / max(1, desiredWidth), size.height / max(1, desiredHeight))
        let width = desiredWidth * fit
        let height = desiredHeight * fit
        let x = center.x.isFinite ? center.x : 0.19
        let y = center.y.isFinite ? center.y : 0.20
        return CGRect(
            x: min(max(x * size.width - width / 2, 0), max(0, size.width - width)),
            y: min(max(y * size.height - height / 2, 0), max(0, size.height - height)),
            width: width, height: height
        )
    }
}

struct CaptureComposition: Equatable {
    let layout: CaptureLayout
    let primarySide: CameraSide

    var secondarySide: CameraSide { primarySide.secondary }
    /// Core Animation sublayer order from back to front.
    var previewLayerOrder: [CameraSide] { [primarySide, secondarySide] }
    /// Hit testing checks the visible overlay before the full-screen layer beneath it.
    var tapHitTestOrder: [CameraSide] { [secondarySide, primarySide] }
}

/// Immutable settings for the single video file written while a dual-camera recording is active.
struct RealtimeRecordingConfiguration: Equatable {
    let layout: CaptureLayout
    let primarySide: CameraSide
    let renderSize: CGSize
    let pictureInPicture: PictureInPictureSettings

    init(
        layout: CaptureLayout,
        primarySide: CameraSide,
        renderSize: CGSize = CGSize(width: 1080, height: 1920),
        pictureInPicture: PictureInPictureSettings = .init()
    ) {
        self.layout = layout
        self.primarySide = primarySide
        self.renderSize = renderSize
        self.pictureInPicture = pictureInPicture
    }

    var secondarySide: CameraSide { primarySide.secondary }

    // 保留预览的宽高比，偶数像素尺寸满足 H.264 编码要求。
    static func renderSize(for previewSize: CGSize) -> CGSize {
        guard previewSize.width.isFinite, previewSize.height.isFinite,
              previewSize.width > 0, previewSize.height > 0 else { return CGSize(width: 1080, height: 1920) }
        let scale = min(1080 / min(previewSize.width, previewSize.height),
                        1920 / max(previewSize.width, previewSize.height))
        return CGSize(width: max(2, (previewSize.width * scale / 2).rounded() * 2),
                      height: max(2, (previewSize.height * scale / 2).rounded() * 2))
    }
}

/// Frames use a top-left origin, matching the preview and the app's visible recording layout.
struct RealtimeVideoFrames: Equatable {
    let primary: CGRect
    let secondary: CGRect
    let secondaryCornerRadius: CGFloat
}

enum RealtimeVideoLayout {
    static func frames(for configuration: RealtimeRecordingConfiguration) -> RealtimeVideoFrames {
        let renderSize = configuration.renderSize

        switch configuration.layout {
        case .pictureInPicture:
            let secondary = configuration.pictureInPicture.frame(in: renderSize)

            return RealtimeVideoFrames(
                primary: CGRect(origin: .zero, size: renderSize),
                secondary: secondary,
                secondaryCornerRadius: configuration.pictureInPicture.shape == .circle ? secondary.width / 2 : 24 * secondary.width / (renderSize.width * PictureInPictureMetrics.widthRatio)
            )

        case .split:
            let splitFrames = VideoLayoutFrames.splitFrames(in: renderSize)
            return RealtimeVideoFrames(
                primary: splitFrames.top,
                secondary: splitFrames.bottom,
                secondaryCornerRadius: 0
            )
        case .sideBySide:
            let half = renderSize.width / 2
            return RealtimeVideoFrames(
                primary: CGRect(x: 0, y: 0, width: half, height: renderSize.height),
                secondary: CGRect(x: half, y: 0, width: half, height: renderSize.height),
                secondaryCornerRadius: 0)
        case .fullScreen:
            return RealtimeVideoFrames(primary: CGRect(origin: .zero, size: renderSize), secondary: .zero, secondaryCornerRadius: 0)
        }
    }

    static func secondaryFrame(
        for configuration: RealtimeRecordingConfiguration,
        in bounds: CGRect
    ) -> CGRect {
        let scaled = scaledFrame(frames(for: configuration).secondary, configuration: configuration, in: bounds)
        guard configuration.layout == .pictureInPicture, configuration.pictureInPicture.shape == .circle else { return scaled }
        let diameter = min(scaled.width, scaled.height, bounds.width, bounds.height)
        return CGRect(x: min(max(scaled.midX - diameter / 2, bounds.minX), bounds.maxX - diameter),
                      y: min(max(scaled.midY - diameter / 2, bounds.minY), bounds.maxY - diameter),
                      width: diameter, height: diameter)
    }

    static func scaledFrame(_ canonical: CGRect, configuration: RealtimeRecordingConfiguration, in bounds: CGRect) -> CGRect {
        let renderSize = configuration.renderSize
        return CGRect(
            x: bounds.minX + canonical.minX * bounds.width / renderSize.width,
            y: bounds.minY + canonical.minY * bounds.height / renderSize.height,
            width: canonical.width * bounds.width / renderSize.width,
            height: canonical.height * bounds.height / renderSize.height
        )
    }

    static func secondaryCornerRadius(
        for configuration: RealtimeRecordingConfiguration,
        in bounds: CGRect
    ) -> CGFloat {
        if configuration.layout == .pictureInPicture, configuration.pictureInPicture.shape == .circle {
            return secondaryFrame(for: configuration, in: bounds).width / 2
        }
        let renderSize = configuration.renderSize
        let scale = min(bounds.width / renderSize.width, bounds.height / renderSize.height)
        return frames(for: configuration).secondaryCornerRadius * scale
    }
}

enum FramePairingPolicy {
    /// Both camera outputs can have a small, stable timestamp offset. The most recent
    /// frame from either output is still a valid composite partner; the recorder keeps
    /// the primary stream as the output clock and enforces monotonic output timestamps.
    static func shouldWrite(primaryTime: Double, secondaryTime: Double?) -> Bool {
        guard let secondaryTime else { return false }
        return primaryTime.isFinite && secondaryTime.isFinite
    }
}

enum RealtimeRecordingState: Equatable {
    case idle
    case recording
    case finishing
    case finished
}

struct RealtimeRecordingStateMachine: Equatable {
    private(set) var state: RealtimeRecordingState = .idle

    var acceptsSamples: Bool { state == .recording }

    mutating func start() {
        guard state == .idle || state == .finished else { return }
        state = .recording
    }

    mutating func beginFinishing() {
        guard state == .recording else { return }
        state = .finishing
    }

    mutating func finish() {
        guard state == .finishing else { return }
        state = .finished
    }
}

struct RecordingPipelinePlan: Equatable {
    let outputFileCount: Int
    let requiresPostProcessing: Bool
    let supportsIndependentCameraFiles: Bool

    static let realtimeComposite = RecordingPipelinePlan(
        outputFileCount: 1,
        requiresPostProcessing: false,
        supportsIndependentCameraFiles: false
    )
}
