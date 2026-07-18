import XCTest
@testable import DualCapture

final class CaptureCompositionTests: XCTestCase {
    func testFrontPrimaryCompositionMakesRearCameraSecondary() {
        let composition = CaptureComposition(layout: .pictureInPicture, primarySide: .front)

        XCTAssertEqual(composition.secondarySide, .rear)
    }

    func testPreviewPlacesSecondaryCameraAbovePrimaryCamera() {
        let composition = CaptureComposition(layout: .pictureInPicture, primarySide: .front)

        XCTAssertEqual(composition.previewLayerOrder, [CameraSide.front, CameraSide.rear])
    }

    func testTapChecksSecondaryCameraBeforeFullScreenPrimaryCamera() {
        let composition = CaptureComposition(layout: .pictureInPicture, primarySide: .front)

        XCTAssertEqual(composition.tapHitTestOrder, [CameraSide.rear, CameraSide.front])
    }
}
