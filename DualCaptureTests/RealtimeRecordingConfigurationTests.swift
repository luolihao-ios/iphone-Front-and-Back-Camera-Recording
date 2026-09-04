import XCTest
@testable import DualCapture

final class RealtimeRecordingConfigurationTests: XCTestCase {
    func testPictureInPictureUsesPortraitCanvasAndPlacesSecondaryAtTopRight() {
        let configuration = RealtimeRecordingConfiguration(
            layout: .pictureInPicture,
            primarySide: .rear
        )

        let frames = RealtimeVideoLayout.frames(for: configuration)

        XCTAssertEqual(configuration.renderSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(frames.primary, CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(frames.secondary.origin.x, 788.4, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.origin.y, 192, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.width, 237.6, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.height, 345.6, accuracy: 0.001)
        XCTAssertGreaterThan(frames.secondaryCornerRadius, 0)
    }

    func testSplitLayoutAlwaysDividesFinalPortraitVideoIntoEqualHalves() {
        let configuration = RealtimeRecordingConfiguration(
            layout: .split,
            primarySide: .front
        )

        let frames = RealtimeVideoLayout.frames(for: configuration)

        XCTAssertEqual(frames.primary, CGRect(x: 0, y: 0, width: 1080, height: 960))
        XCTAssertEqual(frames.secondary, CGRect(x: 0, y: 960, width: 1080, height: 960))
        XCTAssertEqual(frames.secondaryCornerRadius, 0)
    }

    func testFramePairingRequiresASecondaryFrameThatIsNotFromTheFuture() {
        XCTAssertFalse(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: nil))
        XCTAssertFalse(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 1.1))
        XCTAssertTrue(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 0.99))
    }
}
