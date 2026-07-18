import Foundation

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
