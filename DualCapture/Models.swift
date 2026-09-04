import Foundation

enum PictureInPictureMetrics {
    static let widthRatio: CGFloat = 0.22
    static let heightRatio: CGFloat = 0.18
    static let rightMarginRatio: CGFloat = 0.05
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

    var id: String { rawValue }
    var title: String { self == .pictureInPicture ? "画中画" : "分屏" }
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

    init(
        layout: CaptureLayout,
        primarySide: CameraSide,
        renderSize: CGSize = CGSize(width: 1080, height: 1920)
    ) {
        self.layout = layout
        self.primarySide = primarySide
        self.renderSize = renderSize
    }

    var secondarySide: CameraSide { primarySide.secondary }
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
            let secondaryWidth = renderSize.width * PictureInPictureMetrics.widthRatio
            let secondaryHeight = renderSize.height * PictureInPictureMetrics.heightRatio
            let secondary = CGRect(
                x: renderSize.width - secondaryWidth - (renderSize.width * PictureInPictureMetrics.rightMarginRatio),
                y: renderSize.height * PictureInPictureMetrics.topMarginRatio,
                width: secondaryWidth,
                height: secondaryHeight
            )

            return RealtimeVideoFrames(
                primary: CGRect(origin: .zero, size: renderSize),
                secondary: secondary,
                secondaryCornerRadius: 24
            )

        case .split:
            let splitFrames = VideoLayoutFrames.splitFrames(in: renderSize)
            return RealtimeVideoFrames(
                primary: splitFrames.top,
                secondary: splitFrames.bottom,
                secondaryCornerRadius: 0
            )
        }
    }
}

enum FramePairingPolicy {
    /// A secondary image may only be combined with a primary frame when it was captured
    /// at the same instant or earlier. This prevents the final file from showing time
    /// moving backwards in one camera.
    static func shouldWrite(primaryTime: Double, secondaryTime: Double?) -> Bool {
        guard let secondaryTime else { return false }
        return secondaryTime <= primaryTime
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

struct RecordingFiles {
    let front: URL
    let rear: URL
    let composite: URL
}

struct SaveSelection {
    var composite = true
    var front = true
    var rear = true
}
