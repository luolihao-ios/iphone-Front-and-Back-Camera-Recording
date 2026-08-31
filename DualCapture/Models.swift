import Foundation

enum PictureInPictureMetrics {
    static let widthRatio: CGFloat = 0.22
    static let heightRatio: CGFloat = 0.18
    static let rightMarginRatio: CGFloat = 0.05
    static let topMarginRatio: CGFloat = 0.10
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
