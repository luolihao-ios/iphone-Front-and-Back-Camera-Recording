import XCTest
@testable import DualCapture

final class CaptureFormatPolicyTests: XCTestCase {
    private func format(_ id: Int, _ width: CGFloat, _ height: CGFloat, fov: Double = 70,
                        multiCam: Bool = true, fps30: Bool = true, binned: Bool = true) -> CaptureFormatCandidate {
        .init(id: id, dimensions: CGSize(width: width, height: height), horizontalFieldOfView: fov,
              supportsMultiCam: multiCam, supports30FPS: fps30, isBinned: binned)
    }

    func testFourByThreePreservesMoreCircularFieldThanSixteenByNineWithSameLens() throws {
        let wide = format(1, 1920, 1080)
        let full = format(2, 1920, 1440)
        XCTAssertEqual(CaptureFormatPolicy.ranked([wide, full]).first?.id, 2)
        XCTAssertGreaterThan(full.circularFieldOfView, wide.circularFieldOfView)
    }

    func testRanksActualFieldOfViewRatherThanBlindlyChoosingAspectRatio() {
        let narrowFull = format(1, 1440, 1080, fov: 45)
        let wideLens = format(2, 1920, 1080, fov: 100)
        XCTAssertEqual(CaptureFormatPolicy.ranked([narrowFull, wideLens]).first?.id, 2)
    }

    func testRejectsUnsupportedMultiCamAndFrameRate() {
        let result = CaptureFormatPolicy.ranked([
            format(1, 1920, 1440, multiCam: false), format(2, 1920, 1440, fps30: false),
            format(3, 1280, 960)
        ])
        XCTAssertEqual(result.map(\.id), [3])
    }

    func testAvoidsFourKProcessingAndPrefersBinningWhenFieldOfViewMatches() {
        let result = CaptureFormatPolicy.ranked([
            format(1, 3840, 2880), format(2, 1920, 1440, binned: false), format(3, 1920, 1440)
        ])
        XCTAssertEqual(result.first?.id, 3)
        XCTAssertFalse(result.contains { $0.id == 1 })
    }

    func testBudgetFallbackReducesProcessingWhilePreservingBestAvailableCircle() throws {
        let current = format(1, 1920, 1440)
        let candidates = [current, format(2, 1280, 720), format(3, 1280, 960)]
        XCTAssertEqual(CaptureFormatPolicy.lowerCostCandidate(than: current, from: candidates)?.id, 3)
    }

    func testLargestCircleUsesEntireShortSideOfSourceWithoutAdditionalZoom() {
        XCTAssertEqual(CameraFrameGeometry.largestCircleBounds(in: CGRect(x: 0, y: 0, width: 1080, height: 1440)),
                       CGRect(x: 0, y: 180, width: 1080, height: 1080))
        XCTAssertEqual(CameraFrameGeometry.largestCircleBounds(in: CGRect(x: 10, y: 20, width: 1600, height: 900)),
                       CGRect(x: 360, y: 20, width: 900, height: 900))
        XCTAssertEqual(CameraFrameGeometry.largestCircleBounds(in: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
                       CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }
}
