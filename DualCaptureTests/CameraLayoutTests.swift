import XCTest
import CoreImage
@testable import DualCapture

final class CameraLayoutTests: XCTestCase {
    func testFullScreenHasNoSecondaryFrame() {
        let frames = RealtimeVideoLayout.frames(for: .init(layout: .fullScreen, primarySide: .rear))
        XCTAssertEqual(frames.primary, CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertEqual(frames.secondary, .zero)
    }

    func testSideBySideIsExactlyHalfAndHalf() {
        let frames = RealtimeVideoLayout.frames(for: .init(layout: .sideBySide, primarySide: .front))
        XCTAssertEqual(frames.primary, CGRect(x: 0, y: 0, width: 540, height: 1920))
        XCTAssertEqual(frames.secondary, CGRect(x: 540, y: 0, width: 540, height: 1920))
    }

    func testCircleStaysRoundAtEverySupportedSizeAndPosition() {
        for scale in [0.6, 1.0, 1.8] {
            let pip = PictureInPictureSettings(shape: .circle, scale: scale, center: CGPoint(x: 2, y: -1))
            let config = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear, pictureInPicture: pip)
            let frames = RealtimeVideoLayout.frames(for: config)
            XCTAssertEqual(frames.secondary.width, frames.secondary.height, accuracy: 0.001)
            XCTAssertEqual(frames.secondaryCornerRadius, frames.secondary.width / 2, accuracy: 0.001)
            XCTAssertTrue(CGRect(origin: .zero, size: config.renderSize).contains(frames.secondary))
        }
    }

    func testRectangleScalesBothDimensionsWithoutChangingAspectRatio() {
        let normal = RealtimeVideoLayout.frames(for: .init(layout: .pictureInPicture, primarySide: .rear)).secondary
        let large = RealtimeVideoLayout.frames(for: .init(layout: .pictureInPicture, primarySide: .rear,
            pictureInPicture: .init(scale: 1.5))).secondary
        XCTAssertEqual(large.width / normal.width, 1.5, accuracy: 0.001)
        XCTAssertEqual(large.height / normal.height, 1.5, accuracy: 0.001)
    }

    func testPreviewAndOutputUseIdenticalGeometryAfterDragging() {
        let size = CGSize(width: 390, height: 844)
        let config = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear,
            renderSize: RealtimeRecordingConfiguration.renderSize(for: size),
            pictureInPicture: .init(shape: .circle, scale: 1.4, center: CGPoint(x: 0.7, y: 0.65)))
        let frame = RealtimeVideoLayout.secondaryFrame(for: config, in: CGRect(origin: .zero, size: size))
        let output = RealtimeVideoLayout.frames(for: config).secondary
        XCTAssertEqual(frame.midX / size.width, output.midX / config.renderSize.width, accuracy: 0.001)
        XCTAssertEqual(frame.midY / size.height, output.midY / config.renderSize.height, accuracy: 0.001)
        XCTAssertEqual(frame.width, frame.height, accuracy: 0.2)
    }

    func testCircleCompositingRevealsBackgroundOutsideCircle() throws {
        let config = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear,
            renderSize: CGSize(width: 200, height: 400),
            pictureInPicture: .init(shape: .circle, center: CGPoint(x: 0.5, y: 0.5)))
        let primary = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let secondary = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: primary.extent)
        let composite = try XCTUnwrap(FrameCompositor.composite(primary: primary, secondary: secondary, configuration: config))
        let rect = RealtimeVideoLayout.frames(for: config).secondary
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixel(_ point: CGPoint) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(composite, toBitmap: &bytes, rowBytes: 4,
                bounds: CGRect(x: point.x, y: config.renderSize.height - point.y - 1, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        let center = pixel(CGPoint(x: rect.midX, y: rect.midY))
        let corner = pixel(CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        XCTAssertGreaterThan(center[2], 220)
        XCTAssertLessThan(center[0], 30)
        XCTAssertGreaterThan(corner[0], 220)
        XCTAssertLessThan(corner[2], 30)
    }

    func testFullScreenCompositesWithoutSecondaryImage() {
        let config = RealtimeRecordingConfiguration(layout: .fullScreen, primarySide: .front)
        let primary = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertNotNil(FrameCompositor.composite(primary: primary, secondary: nil, configuration: config))
        XCTAssertNil(FrameCompositor.composite(primary: primary, secondary: nil,
            configuration: .init(layout: .pictureInPicture, primarySide: .rear)))
    }
}
