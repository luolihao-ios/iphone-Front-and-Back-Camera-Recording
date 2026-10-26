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
    private var loggedSources: [CameraSide] = []
    // 只在 sampleQueue 上读写；录制期间保持输出方向，结束后应用新窗口方向。
    private var pendingCaptureOrientation: AVCaptureVideoOrientation = .portrait
    private var appliedCaptureOrientation: AVCaptureVideoOrientation = .portrait

    func prepare() async {
        DebugLog.shared.log("prepare.begin")
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DebugLog.shared.log("prepare.unsupported_multicam")
            setStatus("此设备不支持前后摄像头同时录制。")
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
            try fitCaptureHardwareBudget()
            DispatchQueue.main.async {
                self.isSupported = true
                self.statusMessage = "正在启动双摄会话…"
            }
            sampleQueue.async {
                self.applyPendingCaptureOrientation()
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
        sampleQueue.sync {
            self.realtimeRecorder = nil
            self.applyPendingCaptureOrientation()
        }
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
        guard let (front, rear) = supportedCameraPair(),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.missingDevice }
        DebugLog.shared.log("capture.devices front=\(front.deviceType.rawValue) rear=\(rear.deviceType.rawValue)")
        DispatchQueue.main.async { self.hasTorch = rear.hasTorch }
        for (side, device) in [(CameraSide.front, front), (CameraSide.rear, rear)] {
            logCaptureFormat(device.activeFormat, side: side, phase: "original")
            let candidates = captureCandidates(for: device)
            for candidate in CaptureFormatPolicy.ranked(candidates) {
                DebugLog.shared.log("capture.candidate side=\(side) id=\(candidate.id) size=\(candidate.dimensions) horizontalFOV=\(candidate.horizontalFieldOfView) circularFOV=\(candidate.circularFieldOfView) binned=\(candidate.isBinned)")
            }
            if let selected = CaptureFormatPolicy.ranked(candidates).first {
                try applyCaptureFormat(device.formats[selected.id], to: device)
            }
            logCaptureFormat(device.activeFormat, side: side, phase: "selected")
        }
        let frontInput = try AVCaptureDeviceInput(device: front)
        let rearInput = try AVCaptureDeviceInput(device: rear)
        let audioInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(frontInput), session.canAddInput(rearInput), session.canAddInput(audioInput) else { throw CaptureError.unsupportedCombination }
        session.addInputWithNoConnections(frontInput)
        session.addInputWithNoConnections(rearInput)
        session.addInputWithNoConnections(audioInput)
        let frameDuration = CMTime(value: 1, timescale: 30)
        for input in [frontInput, rearInput] where supports30FPS(input.device.activeFormat) {
            input.videoMinFrameDurationOverride = frameDuration
        }

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
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        try connect(input: audioInput, mediaType: .audio, output: audioOutput)
        self.frontOutput = frontOutput
        self.rearOutput = rearOutput
        self.audioOutput = audioOutput
    }

    private func supportedCameraPair() -> (AVCaptureDevice, AVCaptureDevice)? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .unspecified)
        let preferredFront = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        let preferredRear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let fronts = discovery.devices.filter { $0.position == .front }.sorted {
            ($0.uniqueID == preferredFront?.uniqueID ? 0 : 1) < ($1.uniqueID == preferredFront?.uniqueID ? 0 : 1)
        }
        let rears = discovery.devices.filter { $0.position == .back }.sorted {
            ($0.uniqueID == preferredRear?.uniqueID ? 0 : 1) < ($1.uniqueID == preferredRear?.uniqueID ? 0 : 1)
        }
        for front in fronts {
            for rear in rears where discovery.supportedMultiCamDeviceSets.contains(where: { set in
                set.contains(front) && set.contains(rear)
            }) { return (front, rear) }
        }
        return nil
    }

    func updateCaptureOrientation(_ orientation: UIInterfaceOrientation) {
        guard let videoOrientation = CameraOrientation.videoOrientation(for: orientation) else { return }
        sampleQueue.async {
            self.pendingCaptureOrientation = videoOrientation
            self.applyPendingCaptureOrientation()
        }
    }

    private func applyPendingCaptureOrientation() {
        guard realtimeRecorder == nil else { return }
        let connections = [frontOutput, rearOutput].compactMap { $0?.connection(with: .video) }
        guard connections.count == 2 else { return }
        guard appliedCaptureOrientation != pendingCaptureOrientation || connections.contains(where: {
            $0.videoOrientation != pendingCaptureOrientation
        }) else { return }
        for connection in connections where connection.isVideoOrientationSupported {
            connection.videoOrientation = pendingCaptureOrientation
        }
        appliedCaptureOrientation = pendingCaptureOrientation
        latestFrontSample = nil
        latestRearSample = nil
        loggedSources.removeAll()
        DebugLog.shared.log("capture.orientation applied=\(appliedCaptureOrientation.rawValue)")
    }

    private func supports30FPS(_ format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
    }

    private func captureCandidates(for device: AVCaptureDevice) -> [CaptureFormatCandidate] {
        device.formats.enumerated().map { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CaptureFormatCandidate(id: index, dimensions: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
                horizontalFieldOfView: Double(format.videoFieldOfView), supportsMultiCam: format.isMultiCamSupported,
                supports30FPS: supports30FPS(format), isBinned: format.isVideoBinned)
        }
    }

    private func applyCaptureFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        if supports30FPS(format) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        device.videoZoomFactor = min(max(1, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func fitCaptureHardwareBudget() throws {
        let inputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        // 先以最大圆形视野选择格式，再按系统报告的双摄预算逐级降低像素处理量。
        while session.hardwareCost > 1 {
            let reductions = inputs.compactMap { input -> (AVCaptureDeviceInput, CaptureFormatCandidate)? in
                let candidates = captureCandidates(for: input.device)
                guard let index = input.device.formats.firstIndex(of: input.device.activeFormat),
                      let current = candidates.first(where: { $0.id == index }),
                      let lower = CaptureFormatPolicy.lowerCostCandidate(than: current, from: candidates) else { return nil }
                return (input, lower)
            }
            guard let (input, lower) = reductions.max(by: {
                let first = CMVideoFormatDescriptionGetDimensions($0.0.device.activeFormat.formatDescription)
                let second = CMVideoFormatDescriptionGetDimensions($1.0.device.activeFormat.formatDescription)
                return Int64(first.width) * Int64(first.height) < Int64(second.width) * Int64(second.height)
            }) else { throw CaptureError.unsupportedCombination }
            session.beginConfiguration()
            do {
                try applyCaptureFormat(input.device.formats[lower.id], to: input.device)
                input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30)
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()
                throw error
            }
            DebugLog.shared.log("capture.budget_reduced side=\(input.device.position.rawValue) size=\(lower.dimensions) circularFOV=\(lower.circularFieldOfView) hardware=\(session.hardwareCost)")
        }
        DebugLog.shared.log("capture.cost hardware=\(session.hardwareCost) pressure=\(session.systemPressureCost)")
        for input in inputs {
            logCaptureFormat(input.device.activeFormat, side: input.device.position == .front ? .front : .rear, phase: "final")
        }
    }

    private func logCaptureFormat(_ format: AVCaptureDevice.Format, side: CameraSide, phase: String) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        DebugLog.shared.log("capture.format phase=\(phase) side=\(side) native=\(dimensions.width)x\(dimensions.height) horizontalFOV=\(format.videoFieldOfView) binned=\(format.isVideoBinned) multiCam=\(format.isMultiCamSupported)")
    }

    private func makeVideoOutput(side: CameraSide) -> AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = false
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
        if mediaType == .video, connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        guard session.canAddConnection(connection) else { throw CaptureError.unsupportedCombination }
        session.addConnection(connection)
    }

    private func appendVideo(_ sample: CMSampleBuffer, side: CameraSide) {
        if !loggedSources.contains(side), let buffer = CMSampleBufferGetImageBuffer(sample) {
            loggedSources.append(side)
            let circle = CameraFrameGeometry.largestCircleBounds(in: CGRect(x: 0, y: 0,
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            DebugLog.shared.log("capture.actual side=\(side) delivered=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) largestCircle=\(circle)")
        }
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
