import AVFoundation

final class MovieRecorder {
    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private var started = false

    init(url: URL, videoSettings: [String: Any]) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 96_000])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput); writer.add(audioInput)
    }

    func appendVideo(_ sample: CMSampleBuffer, sessionStartTime: CMTime) {
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sessionStartTime)
            started = true
        }
        if videoInput.isReadyForMoreMediaData { videoInput.append(sample) }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard started, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish() async -> URL? {
        guard started else { return nil }
        videoInput.markAsFinished(); audioInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed ? url : nil
    }
}

private enum RecorderError: Error { case cannotAddInput }
