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
    }

    func appendVideo(_ sample: CMSampleBuffer, side: CameraSide) {
        guard stateMachine.acceptsSamples else { return }

        switch side {
        case .front:
            latestFrontSample = sample
        case .rear:
            latestRearSample = sample
        }

        guard side == configuration.primarySide,
              let secondarySample = latestSample(for: configuration.secondarySide) else { return }

        let primaryTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let secondaryTime = CMSampleBufferGetPresentationTimeStamp(secondarySample)
        guard primaryTime.isValid,
              secondaryTime.isValid,
              FramePairingPolicy.shouldWrite(
                primaryTime: primaryTime.seconds,
                secondaryTime: secondaryTime.seconds
              ),
              videoInput.isReadyForMoreMediaData,
              let pixelBuffer = makePixelBuffer(),
              let composite = makeComposite(primarySample: sample, secondarySample: secondarySample) else {
            return
        }

        if !hasStartedWriting {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: primaryTime)
            hasStartedWriting = true
        }

        guard writer.status == .writing else { return }
        context.render(
            composite,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: configuration.renderSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: primaryTime)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard stateMachine.acceptsSamples,
              hasStartedWriting,
              writer.status == .writing,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish() async -> URL? {
        stateMachine.beginFinishing()
        guard hasStartedWriting else {
            stateMachine.finish()
            return nil
        }

        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        stateMachine.finish()
        return writer.status == .completed ? url : nil
    }

    private func latestSample(for side: CameraSide) -> CMSampleBuffer? {
        side == .front ? latestFrontSample : latestRearSample
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferAdaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func makeComposite(primarySample: CMSampleBuffer, secondarySample: CMSampleBuffer) -> CIImage? {
        guard let primaryBuffer = CMSampleBufferGetImageBuffer(primarySample),
              let secondaryBuffer = CMSampleBufferGetImageBuffer(secondarySample) else { return nil }

        let frames = RealtimeVideoLayout.frames(for: configuration)
        let canvas = CGRect(origin: .zero, size: configuration.renderSize)
        let primary = aspectFill(CIImage(cvPixelBuffer: primaryBuffer), into: ciFrame(for: frames.primary)).cropped(to: canvas)
        let secondary = aspectFill(CIImage(cvPixelBuffer: secondaryBuffer), into: ciFrame(for: frames.secondary))

        guard frames.secondaryCornerRadius > 0 else {
            return secondary.composited(over: primary).cropped(to: canvas)
        }

        guard let roundedMask = roundedMask(in: ciFrame(for: frames.secondary), cornerRadius: frames.secondaryCornerRadius),
              let blend = CIFilter(name: "CIBlendWithMask") else {
            return secondary.composited(over: primary).cropped(to: canvas)
        }
        blend.setValue(secondary, forKey: kCIInputImageKey)
        blend.setValue(primary, forKey: kCIInputBackgroundImageKey)
        blend.setValue(roundedMask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: canvas)
    }

    private func aspectFill(_ image: CIImage, into destination: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = destination.midX - scaled.extent.midX
        let y = destination.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y)).cropped(to: destination)
    }

    private func ciFrame(for topLeftFrame: CGRect) -> CGRect {
        CGRect(
            x: topLeftFrame.minX,
            y: configuration.renderSize.height - topLeftFrame.maxY,
            width: topLeftFrame.width,
            height: topLeftFrame.height
        )
    }

    private func roundedMask(in frame: CGRect, cornerRadius: CGFloat) -> CIImage? {
        guard let generator = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        generator.setValue(CIVector(cgRect: frame), forKey: kCIInputExtentKey)
        generator.setValue(cornerRadius, forKey: kCIInputRadiusKey)
        generator.setValue(CIColor.white, forKey: kCIInputColorKey)
        guard let roundedRectangle = generator.outputImage else { return nil }
        let emptyCanvas = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: configuration.renderSize))
        return roundedRectangle.composited(over: emptyCanvas)
    }
}

private enum RealtimeCompositeRecorderError: Error {
    case cannotAddInput
}
