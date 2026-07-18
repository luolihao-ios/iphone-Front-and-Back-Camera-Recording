import XCTest
@testable import DualCapture

final class CaptureCompositionTests: XCTestCase {
    func testFrontPrimaryCompositionMakesRearCameraSecondary() {
        let composition = CaptureComposition(layout: .pictureInPicture, primarySide: .front)

        XCTAssertEqual(composition.secondarySide, .rear)
    }
}
