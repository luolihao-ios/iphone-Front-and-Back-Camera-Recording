import XCTest
import AVFoundation
import CoreImage
@testable import DualCapture

final class VideoSaveFeedbackTests: XCTestCase {
    @MainActor
    func testRealtimeMovieImmediatelyProvidesImageForSaveAnimation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try RealtimeCompositeRecorder(url: url,
            configuration: .init(layout: .pictureInPicture, primarySide: .rear,
                renderSize: CGSize(width: 240, height: 400)))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 240, 400, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 1, green: 0, blue: 0)), to: pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
            formatDescriptionOut: &description), noErr)
        let format = try XCTUnwrap(description)
        recorder.start()
        for index in 0..<12 {
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: Int64(3_000_000 + index), timescale: 30), decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            let frame = try XCTUnwrap(sample)
            recorder.appendVideo(frame, side: .front)
            recorder.appendVideo(frame, side: .rear)
            try await Task.sleep(for: .milliseconds(35))
        }
        let result = await recorder.finish()
        XCTAssertEqual(result, url)
        let image = await ContentView.makeThumbnail(for: url)
        XCTAssertNotNil(image, "录像已成功写入，但提图返回 nil 会让保存动效被整个跳过")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
    }
}
