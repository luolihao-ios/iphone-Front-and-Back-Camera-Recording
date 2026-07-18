import AVFoundation
import SwiftUI

enum CameraSide { case front, rear }

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureMultiCamSession()
    @Published private(set) var isSupported = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage: String?

    var previewSink: ((CameraSide, CMSampleBuffer) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.dualcapture.samples")
    private var frontRecorder: MovieRecorder?
    private var rearRecorder: MovieRecorder?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var rearOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let delegateRegistry = CaptureDelegateRegistry()
    private var recordingStartTime: CMTime?
    private var receivedFrontFrame = false
    private var receivedRearFrame = false

    func prepare() async {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            setStatus("此 iPhone 不支持前后摄像头同时录制。")
            return
        }
        guard await requestPermissions() else {
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
                DispatchQueue.main.async {
                    self.isReady = self.session.isRunning
                    self.statusMessage = self.session.isRunning ? "等待前后摄像头画面…" : "双摄会话未能启动。"
                }
            }
        } catch {
            setStatus("无法配置双摄会话：\(error.localizedDescription)")
        }
    }

    func startRecording() {
        guard isReady, !isRecording else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let frontSettings = frontOutput?.recommendedVideoSettingsForAssetWriter(writingTo: .mov),
                  let rearSettings = rearOutput?.recommendedVideoSettingsForAssetWriter(writingTo: .mov) else {
                throw CaptureError.unsupportedCombination
            }
            frontRecorder = try MovieRecorder(url: folder.appendingPathComponent("front.mov"), videoSettings: frontSettings)
            rearRecorder = try MovieRecorder(url: folder.appendingPathComponent("rear.mov"), videoSettings: rearSettings)
            recordingStartTime = nil
            isRecording = true
            statusMessage = "正在同步录制"
        } catch {
            setStatus("无法创建录制文件：\(error.localizedDescription)")
        }
    }

    func stopRecording(layout: CaptureLayout) async -> RecordingFiles? {
        guard isRecording, let frontRecorder, let rearRecorder else { return nil }
        isRecording = false
        isProcessing = true
        statusMessage = "正在生成视频…"
        self.frontRecorder = nil
        self.rearRecorder = nil
        recordingStartTime = nil
        let frontURL = await frontRecorder.finish()
        let rearURL = await rearRecorder.finish()
        guard let frontURL, let rearURL else {
            isProcessing = false
            setStatus("视频写入失败，请重试。")
            return nil
        }
        do {
            let composite = try await VideoComposer.makeComposite(front: frontURL, rear: rearURL, layout: layout)
            isProcessing = false
            statusMessage = "录制完成：请选择要保存的文件。"
            return RecordingFiles(front: frontURL, rear: rearURL, composite: composite)
        } catch {
            isProcessing = false
            setStatus("合成视频失败：\(error.localizedDescription)")
            return nil
        }
    }

    func save(files: RecordingFiles, selection: SaveSelection) async {
        let urls = [selection.composite ? files.composite : nil, selection.front ? files.front : nil, selection.rear ? files.rear : nil].compactMap { $0 }
        do {
            try await PhotoLibrarySaver.save(urls)
            statusMessage = "已保存到照片图库。"
        } catch {
            setStatus("保存失败：\(error.localizedDescription)")
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
        guard session.canAddConnection(connection) else { throw CaptureError.unsupportedCombination }
        session.addConnection(connection)
    }

    private func appendVideo(_ sample: CMSampleBuffer, side: CameraSide) {
        previewSink?(side, sample)
        reportFirstFrame(for: side)
        guard isRecording else { return }
        let startTime = recordingStartTime ?? CMSampleBufferGetPresentationTimeStamp(sample)
        recordingStartTime = startTime
        switch side { case .front: frontRecorder?.appendVideo(sample, sessionStartTime: startTime); case .rear: rearRecorder?.appendVideo(sample, sessionStartTime: startTime) }
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard isRecording else { return }
        frontRecorder?.appendAudio(sample)
        rearRecorder?.appendAudio(sample)
    }

    private func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return camera && audio
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async { self.statusMessage = message }
    }

    private func reportFirstFrame(for side: CameraSide) {
        switch side {
        case .front: receivedFrontFrame = true
        case .rear: receivedRearFrame = true
        }
        guard receivedFrontFrame || receivedRearFrame else { return }
        let text: String
        switch (receivedRearFrame, receivedFrontFrame) {
        case (true, true): text = "已接收前后摄像头画面。"
        case (true, false): text = "已接收后摄画面，等待前摄画面…"
        case (false, true): text = "已接收前摄画面，等待后摄画面…"
        case (false, false): return
        }
        DispatchQueue.main.async { self.statusMessage = text }
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
