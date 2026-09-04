import XCTest
@testable import DualCapture

final class VideoLayoutFramesTests: XCTestCase {
    func testSplitFramesDividePortraitCanvasIntoEqualHalves() {
        let frames = VideoLayoutFrames.splitFrames(in: CGSize(width: 1080, height: 1920))

        XCTAssertEqual(frames.top, CGRect(x: 0, y: 0, width: 1080, height: 960))
        XCTAssertEqual(frames.bottom, CGRect(x: 0, y: 960, width: 1080, height: 960))
    }
}
