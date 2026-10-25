import XCTest
import CoreImage
import AVFoundation
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

    func testCircleUsesLargestAvailableSourceRegionWithoutBlackPaddingAtEverySize() throws {
        let size = CGSize(width: 200, height: 400)
        let source = CGRect(origin: .zero, size: size)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: source)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
        // 最大圆的上、下、左、右边缘均有标记；额外放大或留黑边都会丢掉标记。
        let secondary = green.cropped(to: CGRect(x: 0, y: 270, width: 200, height: 30))
            .composited(over: green.cropped(to: CGRect(x: 0, y: 100, width: 200, height: 30)))
            .composited(over: green.cropped(to: CGRect(x: 0, y: 100, width: 30, height: 200)))
            .composited(over: green.cropped(to: CGRect(x: 170, y: 100, width: 30, height: 200)))
            .composited(over: blue)
        let primary = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: source)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for scale in [0.6, 1.0, 1.8] {
            let configuration = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear,
                renderSize: size, pictureInPicture: .init(shape: .circle, scale: scale, center: CGPoint(x: 0.5, y: 0.5)))
            let image = try XCTUnwrap(FrameCompositor.composite(primary: primary, secondary: secondary, configuration: configuration))
            let frame = RealtimeVideoLayout.frames(for: configuration).secondary
            let points = [CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.1),
                          CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.9),
                          CGPoint(x: frame.minX + frame.width * 0.1, y: frame.midY),
                          CGPoint(x: frame.minX + frame.width * 0.9, y: frame.midY)]
            for point in points {
                var rgba = [UInt8](repeating: 0, count: 4)
                context.render(image, toBitmap: &rgba, rowBytes: 4,
                    bounds: CGRect(x: point.x, y: size.height - point.y, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                XCTAssertGreaterThan(rgba[1], 220, "应保留最大圆的四个方向标记，比例 \(scale)")
                XCTAssertLessThan(rgba[2], 30)
            }
        }
    }

    @MainActor
    func testCirclePreviewFillsLargestCircleAndKeepsGravityConsistentWhenSwitchingShape() throws {
        let view = PreviewView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.configuration = .init(layout: .pictureInPicture, primarySide: .rear,
            pictureInPicture: .init(shape: .circle))
        view.layoutIfNeeded()
        let circleLayers = try XCTUnwrap(view.layer.sublayers).compactMap { $0 as? AVSampleBufferDisplayLayer }
        XCTAssertEqual(circleLayers[1].videoGravity, .resizeAspectFill)
        view.configuration = .init(layout: .pictureInPicture, primarySide: .front)
        view.layoutIfNeeded()
        let rectangularLayers = try XCTUnwrap(view.layer.sublayers).compactMap { $0 as? AVSampleBufferDisplayLayer }
        XCTAssertEqual(rectangularLayers[0].videoGravity, .resizeAspectFill)
        XCTAssertEqual(rectangularLayers[1].videoGravity, .resizeAspectFill)
    }

    @MainActor
    func testFullScreenCameraSwitchNeverLeavesPrimaryLayerHidden() throws {
        let view = PreviewView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let transitions: [(CaptureLayout, CameraSide)] = [
            (.fullScreen, .rear), (.fullScreen, .front), (.split, .rear), (.pictureInPicture, .front)
        ]
        for (layout, primary) in transitions {
            view.configuration = .init(layout: layout, primarySide: primary, renderSize: CGSize(width: 390, height: 844))
            view.layoutIfNeeded()
            let layers = try XCTUnwrap(view.layer.sublayers).compactMap { $0 as? AVSampleBufferDisplayLayer }
            XCTAssertEqual(layers.count, 2)
            XCTAssertFalse(layers[0].isHidden, "主画面必须可见：\(layout), \(primary)")
            XCTAssertEqual(layers.filter { !$0.isHidden }.count, layout == .fullScreen ? 1 : 2)
        }
    }

    @MainActor
    func testPreviewRemovesRoundClippingWhenSwitchingToEqualSplit() throws {
        let view = PreviewView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.configuration = .init(layout: .pictureInPicture, primarySide: .rear,
            renderSize: CGSize(width: 390, height: 844), pictureInPicture: .init(shape: .circle))
        view.layoutIfNeeded()
        view.configuration = .init(layout: .split, primarySide: .front, renderSize: CGSize(width: 390, height: 844))
        view.layoutIfNeeded()
        let layers = try XCTUnwrap(view.layer.sublayers).compactMap { $0 as? AVSampleBufferDisplayLayer }
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].frame, CGRect(x: 0, y: 0, width: 390, height: 422))
        XCTAssertEqual(layers[1].frame, CGRect(x: 0, y: 422, width: 390, height: 422))
        XCTAssertEqual(layers[0].cornerRadius, 0)
        XCTAssertEqual(layers[1].cornerRadius, 0)
    }

    func testFullScreenRecorderWritesWithoutReceivingSecondaryFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try RealtimeCompositeRecorder(url: url, configuration: .init(layout: .fullScreen,
            primarySide: .rear, renderSize: CGSize(width: 200, height: 400)))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 200, 400, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: .white), to: pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
            formatDescriptionOut: &description), noErr)
        let format = try XCTUnwrap(description)
        recorder.start()
        for index in 0..<6 {
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: Int64(index + 30), timescale: 30), decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            recorder.appendVideo(try XCTUnwrap(sample), side: .rear)
            try await Task.sleep(for: .milliseconds(40))
        }
        let output = await recorder.finish()
        XCTAssertEqual(output, url)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }
}
