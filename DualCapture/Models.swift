import Foundation

enum CaptureLayout: String, CaseIterable, Identifiable {
    case pictureInPicture
    case split

    var id: String { rawValue }
    var title: String { self == .pictureInPicture ? "画中画" : "分屏" }
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
