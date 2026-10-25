import AVFoundation
import SwiftUI
import AudioToolbox
import CoreImage
import UIKit

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureMultiCamSession()
    @Published private(set) var isSupported = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var isTorchOn = false
    @Published private(set) var hasTorch = false

    var previewSink: ((CameraSide, CMSampleBuffer) -> Void)?
    private let sampleQueue = DispatchQueue(label: "com.dualcapture.samples")
    private var realtimeRecorder: RealtimeCompositeRecorder?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var rearOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let delegateRegistry = CaptureDelegateRegistry()
    private var audioRecordingEnabled = false
    private var latestFrontSample: CMSampleBuffer?
    private var latestRearSample: CMSampleBuffer?
    private let photoContext = CIContext(options: [.cacheIntermediates: false])

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

    @MainActor
    func startRecording(configuration: RealtimeRecordingConfiguration) {
        DebugLog.shared.log("record.start.request ready=\(isReady) recording=\(isRecording) layout=\(configuration.layout.rawValue) primary=\(configuration.primarySide)")
        guard isReady, !isRecording, !isProcessing else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recorder = try RealtimeCompositeRecorder(
                url: folder.appendingPathComponent("final.mov"),
                configuration: configuration
            )
            sampleQueue.sync {
                recorder.start()
                realtimeRecorder = recorder
                audioRecordingEnabled = false
            }
            isRecording = true
            DebugLog.shared.log("record.start.success url=\(folder.appendingPathComponent("final.mov").path)")
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
        sampleQueue.sync { audioRecordingEnabled = false }
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
    @MainActor
    func save(videoURL: URL) async -> Bool {
        DebugLog.shared.log("save.begin url=\(videoURL.path)")
        do {
            try await PhotoLibrarySaver.save([videoURL])
            DebugLog.shared.log("save.success")
            statusMessage = nil
            return true
        } catch {
            DebugLog.shared.log("save.error=\(error.localizedDescription)")
            setStatus("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func takePhoto(configuration: RealtimeRecordingConfiguration) async -> UIImage? {
        guard isReady, !isRecording, !isProcessing else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        DebugLog.shared.log("photo.begin layout=\(configuration.layout.rawValue) shape=\(configuration.pictureInPicture.shape.rawValue)")
        let image: UIImage? = await withCheckedContinuation { continuation in
            sampleQueue.async {
                autoreleasepool {
                    let primarySample = configuration.primarySide == .front ? self.latestFrontSample : self.latestRearSample
                    let secondarySample = configuration.secondarySide == .front ? self.latestFrontSample : self.latestRearSample
                    guard let primarySample, let primary = CMSampleBufferGetImageBuffer(primarySample) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let secondary = secondarySample.flatMap(CMSampleBufferGetImageBuffer).map { CIImage(cvPixelBuffer: $0) }
                    guard let composite = FrameCompositor.composite(primary: CIImage(cvPixelBuffer: primary), secondary: secondary, configuration: configuration),
                          let cgImage = self.photoContext.createCGImage(composite, from: composite.extent) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                }
            }
        }
        guard let image else {
            setStatus("尚未收到完整相机画面，请稍后重试。")
            return nil
        }
        do {
            try await PhotoLibrarySaver.save(image: image)
            DebugLog.shared.log("photo.saved")
            return image
        } catch {
            DebugLog.shared.log("photo.failed \(error.localizedDescription)")
            setStatus("照片保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    func toggleTorch() {
        guard !isRecording, !isProcessing else { return }
        sampleQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let enabled = device.torchMode != .on
                device.torchMode = enabled ? .on : .off
                DispatchQueue.main.async { self.isTorchOn = enabled }
            } catch { self.setStatus("无法开启补光灯：\(error.localizedDescription)") }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = true
        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.missingDevice }
        DispatchQueue.main.async { self.hasTorch = rear.hasTorch }
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
        if side == .front { latestFrontSample = sample } else { latestRearSample = sample }
        previewSink?(side, sample)
        realtimeRecorder?.appendVideo(sample, side: side)
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard audioRecordingEnabled else { return }
        realtimeRecorder?.appendAudio(sample)
    }

    private func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return camera && audio
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            self.errorMessage = message
        }
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
