import AVFoundation
import SwiftUI
import AudioToolbox

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureMultiCamSession()
    @Published private(set) var isSupported = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage: String?

    var previewSink: ((CameraSide, CMSampleBuffer) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.dualcapture.samples")
    private var realtimeRecorder: RealtimeCompositeRecorder?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var rearOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let delegateRegistry = CaptureDelegateRegistry()
    private var audioRecordingEnabled = false

    func prepare() async {
        DebugLog.shared.log("prepare.begin")
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DebugLog.shared.log("prepare.unsupported_multicam")
            setStatus("此 iPhone 不支持前后摄像头同时录制。")
            return
        }
        let permissionsGranted = await requestPermissions()
        DebugLog.shared.log("prepare.permissions=\(permissionsGranted)")
        guard permissionsGranted else {
            setStatus("请在“设置 > 隐私与安全性”中允许相机和麦克风访问。")
            return
        }
        do {
            try configureSession()
            DispatchQueue.main.async {
                self.isSupported = true
                self.statusMessage = "正在启动双摄会话…"
            }
            sampleQueue.async {
                self.session.startRunning()
                DebugLog.shared.log("prepare.session_running=\(self.session.isRunning)")
                DispatchQueue.main.async {
                    self.isReady = self.session.isRunning
                    self.statusMessage = self.session.isRunning ? nil : "双摄会话未能启动。"
                }
            }
        } catch {
            DebugLog.shared.log("prepare.configure_error=\(error.localizedDescription)")
            setStatus("无法配置双摄会话：\(error.localizedDescription)")
        }
    }

    func startRecording(layout: CaptureLayout, primarySide: CameraSide) {
        DebugLog.shared.log("record.start.request ready=\(isReady) recording=\(isRecording) layout=\(layout.rawValue) primary=\(primarySide)")
        guard isReady, !isRecording else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let configuration = RealtimeRecordingConfiguration(layout: layout, primarySide: primarySide)
            let recorder = try RealtimeCompositeRecorder(
                url: folder.appendingPathComponent("final.mov"),
                configuration: configuration
            )
            recorder.start()
            realtimeRecorder = recorder
            isRecording = true
            DebugLog.shared.log("record.start.success url=\(folder.appendingPathComponent("final.mov").path)")
            audioRecordingEnabled = false
            AudioServicesPlaySystemSound(1117)
            sampleQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.audioRecordingEnabled = true
            }
            statusMessage = nil
        } catch {
            DebugLog.shared.log("record.start.error=\(error.localizedDescription)")
            setStatus("无法创建录制文件：\(error.localizedDescription)")
        }
    }

    @MainActor
    func stopRecording() async -> URL? {
        DebugLog.shared.log("record.stop.request recording=\(isRecording) processing=\(isProcessing) hasRecorder=\(realtimeRecorder != nil)")
        guard isRecording else {
            DebugLog.shared.log("record.stop.ignored_not_recording")
            return nil
        }
        guard !isProcessing else {
            DebugLog.shared.log("record.stop.ignored_already_processing")
            return nil
        }
        guard let realtimeRecorder else {
            DebugLog.shared.log("record.stop.error_recorder_missing")
            setStatus("录制器已丢失，请重新开始录制。")
            return nil
        }
        audioRecordingEnabled = false
        AudioServicesPlaySystemSound(1118)
        isProcessing = true
        statusMessage = "正在完成录制…"
        // Yield once so SwiftUI can render the processing state before the
        // writer completion task returns (including the no-frame failure path).
        await Task.yield()

        // Keep the recorder attached while the sample queue drains. The stop
        // request can arrive between the two camera callbacks that form a
        // composite frame; clearing the property here would drop those queued
        // frames and could leave AVAssetWriter with no video samples at all.
        let videoURL = await finish(realtimeRecorder)
        let failureDescription = realtimeRecorder.failureDescription
        DebugLog.shared.log("record.stop.finished url=\(videoURL?.path ?? "nil") writerError=\(failureDescription ?? "none")")
        self.realtimeRecorder = nil
        isRecording = false
        isProcessing = false
        guard let videoURL else {
            let detail = failureDescription.map { "（\($0)）" } ?? ""
            setStatus("视频写入失败\(detail)，请重试。")
            return nil
        }
        statusMessage = nil
        DebugLog.shared.log("record.stop.success")
        return videoURL
    }

    @discardableResult
    func save(videoURL: URL) async -> Bool {
        DebugLog.shared.log("save.begin url=\(videoURL.path)")
        do {
            try await PhotoLibrarySaver.save([videoURL])
            DebugLog.shared.log("save.success")
            statusMessage = "已保存到照片图库。"
            return true
        } catch {
            DebugLog.shared.log("save.error=\(error.localizedDescription)")
            setStatus("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = true
        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.missingDevice }
        let frontInput = try AVCaptureDeviceInput(device: front)
        let rearInput = try AVCaptureDeviceInput(device: rear)
        let audioInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(frontInput), session.canAddInput(rearInput), session.canAddInput(audioInput) else { throw CaptureError.unsupportedCombination }
        session.addInputWithNoConnections(frontInput)
        session.addInputWithNoConnections(rearInput)
        session.addInputWithNoConnections(audioInput)

        let frontOutput = makeVideoOutput(side: .front)
        let rearOutput = makeVideoOutput(side: .rear)
        let audioOutput = AVCaptureAudioDataOutput()
        let audioDelegate = SampleDelegate { [weak self] sample in self?.appendAudio(sample) }
        delegateRegistry.retain(audioDelegate)
        audioOutput.setSampleBufferDelegate(audioDelegate, queue: sampleQueue)
        for output in [frontOutput, rearOutput] { guard session.canAddOutput(output) else { throw CaptureError.unsupportedCombination }; session.addOutputWithNoConnections(output) }
        guard session.canAddOutput(audioOutput) else { throw CaptureError.unsupportedCombination }
        session.addOutputWithNoConnections(audioOutput)
        try connect(input: frontInput, mediaType: .video, output: frontOutput)
        try connect(input: rearInput, mediaType: .video, output: rearOutput)
        if let connection = frontOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
        try connect(input: audioInput, mediaType: .audio, output: audioOutput)
        self.frontOutput = frontOutput
        self.rearOutput = rearOutput
        self.audioOutput = audioOutput
    }

    private func makeVideoOutput(side: CameraSide) -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let delegate = SampleDelegate { [weak self] sample in self?.appendVideo(sample, side: side) }
        delegateRegistry.retain(delegate)
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        return output
    }

    private func connect(input: AVCaptureDeviceInput, mediaType: AVMediaType, output: AVCaptureOutput) throws {
        guard let port = input.ports.first(where: { $0.mediaType == mediaType }) else { throw CaptureError.unsupportedCombination }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        if mediaType == .video, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        guard session.canAddConnection(connection) else { throw CaptureError.unsupportedCombination }
        session.addConnection(connection)
    }

    private func appendVideo(_ sample: CMSampleBuffer, side: CameraSide) {
        previewSink?(side, sample)
        guard isRecording else { return }
        realtimeRecorder?.appendVideo(sample, side: side)
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard isRecording, audioRecordingEnabled else { return }
        realtimeRecorder?.appendAudio(sample)
    }

    private func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return camera && audio
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async { self.statusMessage = message }
    }

    private func finish(_ recorder: RealtimeCompositeRecorder) async -> URL? {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                Task {
                    continuation.resume(returning: await recorder.finish())
                }
            }
        }
    }

}

private enum CaptureError: LocalizedError { case missingDevice, unsupportedCombination
    var errorDescription: String? { self == .missingDevice ? "找不到摄像头或麦克风" : "此机型不支持该双摄组合" }
}

private final class SampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let handler: (CMSampleBuffer) -> Void
    init(_ handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { handler(sampleBuffer) }
}
