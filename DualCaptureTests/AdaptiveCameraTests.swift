import XCTest
import AVFoundation
@testable import DualCapture

final class AdaptiveCameraTests: XCTestCase {
    func testLargestCircleStaysInsideShortLandscapeViewport() {
        let size = CGSize(width: 1024, height: 375)
        let frame = PictureInPictureSettings(shape: .circle, scale: 1.8,
            center: CGPoint(x: 0.9, y: 0.9)).frame(in: size)
        XCTAssertEqual(frame.width, frame.height, accuracy: 0.001)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
    }

    func testRecordingCircleRemainsRoundAfterWindowExpands() {
        let configuration = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear,
            renderSize: CGSize(width: 1080, height: 1920), pictureInPicture: .init(shape: .circle))
        let frame = RealtimeVideoLayout.secondaryFrame(for: configuration,
            in: CGRect(x: 0, y: 0, width: 1024, height: 768))
        XCTAssertEqual(frame.width, frame.height, accuracy: 0.001)
    }

    func testCanvasStaysWithinHDEncoderBudgetEvenInVeryTallWindow() {
        let canvas = RealtimeRecordingConfiguration.renderSize(for: CGSize(width: 300, height: 2400))
        XCTAssertLessThanOrEqual(max(canvas.width, canvas.height), 1920)
        XCTAssertGreaterThan(canvas.width, 0)
        XCTAssertEqual(canvas.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(canvas.height.truncatingRemainder(dividingBy: 2), 0)
    }

    @MainActor
    func testPreviewFillsNativeTabletBoundsAndSplitRemainsEqualAfterResize() throws {
        let view = PreviewView(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        for size in [CGSize(width: 768, height: 1024), CGSize(width: 1194, height: 834)] {
            view.frame.size = size
            view.configuration = .init(layout: .split, primarySide: .rear,
                renderSize: RealtimeRecordingConfiguration.renderSize(for: size))
            view.layoutIfNeeded()
            let layers = try XCTUnwrap(view.layer.sublayers).compactMap { $0 as? AVSampleBufferDisplayLayer }
            XCTAssertEqual(layers.count, 2)
            XCTAssertEqual(layers[0].frame.minX, 0, accuracy: 0.001)
            XCTAssertEqual(layers[0].frame.minY, 0, accuracy: 0.001)
            XCTAssertEqual(layers[0].frame.width, size.width, accuracy: 0.001)
            XCTAssertEqual(layers[0].frame.height, size.height / 2, accuracy: 0.001)
            XCTAssertEqual(layers[1].frame.minY, size.height / 2, accuracy: 0.001)
            XCTAssertEqual(layers[1].frame.maxY, size.height, accuracy: 0.001)
        }
    }
}
