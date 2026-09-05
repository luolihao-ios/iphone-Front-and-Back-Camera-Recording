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
        XCTAssertEqual(frames.secondary.origin.x, 54, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.origin.y, 192, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.width, 302.4, accuracy: 0.001)
        XCTAssertEqual(frames.secondary.height, 384, accuracy: 0.001)
        XCTAssertGreaterThan(frames.secondaryCornerRadius, 0)
    }

    func testPreviewUsesTheSamePictureInPictureFrameAsTheOutputCanvas() {
        let configuration = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear)
        let previewBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let previewFrame = RealtimeVideoLayout.secondaryFrame(for: configuration, in: previewBounds)
        let outputFrame = RealtimeVideoLayout.frames(for: configuration).secondary

        XCTAssertEqual(previewFrame.minX / previewBounds.width, outputFrame.minX / configuration.renderSize.width, accuracy: 0.001)
        XCTAssertEqual(previewFrame.minY / previewBounds.height, outputFrame.minY / configuration.renderSize.height, accuracy: 0.001)
        XCTAssertEqual(previewFrame.width / previewBounds.width, outputFrame.width / configuration.renderSize.width, accuracy: 0.001)
        XCTAssertEqual(previewFrame.height / previewBounds.height, outputFrame.height / configuration.renderSize.height, accuracy: 0.001)
        XCTAssertEqual(
            RealtimeVideoLayout.secondaryCornerRadius(for: configuration, in: previewBounds),
            24 * min(previewBounds.width / configuration.renderSize.width, previewBounds.height / configuration.renderSize.height),
            accuracy: 0.001
        )
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

    func testFramePairingAcceptsValidFramesWithEitherCameraTimestampOffset() {
        XCTAssertFalse(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: nil))
        XCTAssertTrue(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 1.1))
        XCTAssertTrue(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 0.99))
    }
}
