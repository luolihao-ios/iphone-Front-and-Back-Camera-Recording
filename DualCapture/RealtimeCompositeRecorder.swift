import AVFoundation
import CoreImage
import Metal

/// Writes the already-composited dual-camera image to one movie file while recording.
/// All methods are called from CameraManager's serial sample queue.
final class RealtimeCompositeRecorder {
    private let url: URL
    private let configuration: RealtimeRecordingConfiguration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private var stateMachine = RealtimeRecordingStateMachine()
    private var hasStartedWriting = false
    private var latestFrontSample: CMSampleBuffer?
    private var latestRearSample: CMSampleBuffer?
    private var lastWrittenPresentationTime: CMTime?
    private var primaryFrameCount = 0
    private var pairedFrameCount = 0
    private var appendedFrameCount = 0
    private var appendFailureCount = 0

    var failureDescription: String? {
        writer.error?.localizedDescription
    }

    init(url: URL, configuration: RealtimeRecordingConfiguration) throws {
        self.url = url
        self.configuration = configuration
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.renderSize.width,
            AVVideoHeightKey: configuration.renderSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RealtimeCompositeRecorderError.cannotAddInput
        }
        writer.add(videoInput)
        writer.add(audioInput)

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.renderSize.width,
                kCVPixelBufferHeightKey as String: configuration.renderSize.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device)
        } else {
            context = CIContext(options: nil)
        }
    }

    func start() {
        stateMachine.start()
        DebugLog.shared.log("writer.start state=\(stateMachine.state)")
        DebugLog.shared.log("writer.layout canvas=\(configuration.renderSize) frames=\(RealtimeVideoLayout.frames(for: configuration)) shape=\(configuration.pictureInPicture.shape.rawValue)")
    }

    func appendVideo(_ sample: CMSampleBuffer, side: CameraSide) {
        guard stateMachine.acceptsSamples else { return }

        if side == configuration.primarySide {
            primaryFrameCount += 1
            if primaryFrameCount == 1 || primaryFrameCount % 30 == 0 {
                DebugLog.shared.log("writer.primary_frames=\(primaryFrameCount) paired=\(pairedFrameCount) appended=\(appendedFrameCount)")
            }
        }

        switch side {
        case .front:
            latestFrontSample = sample
        case .rear:
            latestRearSample = sample
        }

        guard side == configuration.primarySide else { return }
        let secondarySample = latestSample(for: configuration.secondarySide)
        guard configuration.layout == .fullScreen || secondarySample != nil else { return }
        pairedFrameCount += 1

        let primaryTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let secondaryTime = secondarySample.map(CMSampleBufferGetPresentationTimeStamp) ?? primaryTime
        guard primaryTime.isValid,
              secondaryTime.isValid,
              FramePairingPolicy.shouldWrite(
                primaryTime: primaryTime.seconds,
                secondaryTime: secondaryTime.seconds
              ),
              isAfterLastWrittenFrame(primaryTime),
              let composite = makeComposite(primarySample: sample, secondarySample: secondarySample) else {
            return
        }

        if !hasStartedWriting {
            guard writer.startWriting() else {
                DebugLog.shared.log("writer.startWriting.failed status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
                return
            }
            writer.startSession(atSourceTime: primaryTime)
            hasStartedWriting = true
            DebugLog.shared.log("writer.started session=\(primaryTime.seconds)")
        }

        guard writer.status == .writing else {
            DebugLog.shared.log("writer.not_writing status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
            return
        }
        // Before startWriting(), AVAssetWriterInput may report that it is not
        // ready even though the first frame is exactly what starts the file.
        // Check readiness only after the writer has entered the writing state.
        guard videoInput.isReadyForMoreMediaData else {
            appendFailureCount += 1
            if appendFailureCount == 1 || appendFailureCount % 30 == 0 {
                DebugLog.shared.log("writer.input_not_ready count=\(appendFailureCount)")
            }
            return
        }
        guard let pixelBuffer = makePixelBuffer() else {
            DebugLog.shared.log("writer.pixel_buffer_pool_missing")
            return
        }
        context.render(
            composite,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: configuration.renderSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: primaryTime) else {
            appendFailureCount += 1
            DebugLog.shared.log("writer.append.failed count=\(appendFailureCount) status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
            return
        }
        lastWrittenPresentationTime = primaryTime
        appendedFrameCount += 1
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard stateMachine.acceptsSamples,
              hasStartedWriting,
              writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish() async -> URL? {
        DebugLog.shared.log("writer.finish.begin started=\(hasStartedWriting) primary=\(primaryFrameCount) paired=\(pairedFrameCount) appended=\(appendedFrameCount)")
        stateMachine.beginFinishing()
        guard hasStartedWriting else {
            DebugLog.shared.log("writer.finish.no_frames status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
            stateMachine.finish()
            return nil
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        stateMachine.finish()
        DebugLog.shared.log("writer.finish.end status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
        return writer.status == .completed ? url : nil
    }

    private func latestSample(for side: CameraSide) -> CMSampleBuffer? {
        side == .front ? latestFrontSample : latestRearSample
    }

    private func isAfterLastWrittenFrame(_ time: CMTime) -> Bool {
        guard let lastWrittenPresentationTime else { return true }
        return time > lastWrittenPresentationTime
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferAdaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func makeComposite(primarySample: CMSampleBuffer, secondarySample: CMSampleBuffer?) -> CIImage? {
        guard let primaryBuffer = CMSampleBufferGetImageBuffer(primarySample) else { return nil }
        let secondary = secondarySample.flatMap(CMSampleBufferGetImageBuffer).map { CIImage(cvPixelBuffer: $0) }
        return FrameCompositor.composite(primary: CIImage(cvPixelBuffer: primaryBuffer), secondary: secondary, configuration: configuration)
    }
}

private enum RealtimeCompositeRecorderError: Error {
    case cannotAddInput
}
