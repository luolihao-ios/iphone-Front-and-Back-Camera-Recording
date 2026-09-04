import SwiftUI
import UIKit
import AVKit
import Photos

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("saveComposite") private var saveComposite = true
    @AppStorage("saveFront") private var saveFront = false
    @AppStorage("saveRear") private var saveRear = false
    @AppStorage("saveSettingsInitialized") private var saveSettingsInitialized = false
    @AppStorage("successfulSaveCount") private var successfulSaveCount = 0
    @AppStorage("lastReviewPromptedVersion") private var lastReviewPromptedVersion = ""
    @State private var recordingComposition: CaptureComposition?
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var recordingStartedAt: Date?
    @State private var latestVideoURL: URL?
    @State private var latestThumbnail: UIImage?
    @State private var availableUpdate: AppStoreUpdate?

    private var layout: CaptureLayout { CaptureLayout(rawValue: captureLayout) ?? .pictureInPicture }
    private var primarySide: CameraSide { primaryCamera == "front" ? .front : .rear }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.isSupported {
                CameraPreview(camera: camera, layout: layout, primarySide: primarySide) { side in
                    guard !camera.isRecording, side != primarySide else { return }
                    primaryCamera = side == .front ? "front" : "rear"
                }
                .ignoresSafeArea()
            }
            VStack {
                if camera.isRecording, let recordingStartedAt {
                    TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(recordingStartedAt)))
                        HStack(spacing: 7) {
                            Circle().fill(.white).frame(width: 9, height: 9)
                            Text(String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60))
                        }
                        .foregroundStyle(.white)
                        .font(.system(.headline, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.red).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else if camera.isProcessing {
                    ProgressView("正在处理录制…")
                        .tint(.black)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.white.opacity(0.95)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                if camera.isRecording {
                    recordButton()
                        .disabled(camera.isProcessing)
                        .padding(.bottom, 34)
                } else {
                    ZStack {
                        HStack(spacing: 22) {
                        Button(action: switchCamera) {
                            Image(systemName: "camera.rotate").font(.title2)
                                .frame(width: 54, height: 54)
                                .background(.black.opacity(0.55)).clipShape(Circle())
                        }
                        recordButton()
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3").font(.title2)
                                .frame(width: 54, height: 54)
                                .background(.black.opacity(0.55)).clipShape(Circle())
                        }
                        }
                        .frame(maxWidth: .infinity)
                        AlbumThumbnailButton(thumbnail: latestThumbnail) { showPlayer = latestVideoURL != nil }
                            .offset(x: -153)
                    }
                    .disabled(camera.isProcessing)
                    .padding(.bottom, 34)
                }
            }
        }
        .task {
            if !saveSettingsInitialized {
                saveComposite = true
                saveFront = false
                saveRear = false
                saveSettingsInitialized = true
            }
            await camera.prepare()
            let latest = await Self.loadLatestVideo()
            latestThumbnail = latest.thumbnail
            latestVideoURL = latest.url
            if let update = await AppStoreUpdateChecker.fetchAvailableUpdate(installedVersion: AppVersion.current) {
                availableUpdate = update
            } else {
                try? await Task.sleep(for: .seconds(2))
                requestReviewIfAppropriate()
            }
        }
        .alert(item: $availableUpdate) { update in
            Alert(
                title: Text("发现新版本"),
                message: Text("“同框之外”已有 \(update.version) 版本可更新。"),
                primaryButton: .default(Text("前往更新")) { openURL(update.storeURL) },
                secondaryButton: .cancel(Text("暂不"))
            )
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let latestVideoURL { VideoPlayerView(url: latestVideoURL) }
        }
    }

    private func toggleRecording() {
        if camera.isRecording {
            Task {
                guard let composition = recordingComposition else { return }
                recordingStartedAt = nil
                guard let files = await camera.stopRecording(layout: composition.layout, primarySide: composition.primarySide) else { return }
                let selection = SaveSelection(composite: saveComposite, front: saveFront, rear: saveRear)
                if await camera.save(files: files, selection: selection) {
                    let savedURL = selection.composite ? files.composite : (selection.front ? files.front : files.rear)
                    latestVideoURL = savedURL
                    latestThumbnail = await Self.makeThumbnail(for: savedURL)
                    successfulSaveCount += 1
                }
            }
        } else {
            recordingComposition = CaptureComposition(layout: layout, primarySide: primarySide)
            recordingStartedAt = Date()
            camera.startRecording()
        }
    }

    private func switchCamera() {
        guard !camera.isRecording && !camera.isProcessing else { return }
        primaryCamera = primaryCamera == "front" ? "rear" : "front"
    }

    private func recordButton() -> some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle().fill(.black.opacity(0.35)).frame(width: 72, height: 72)
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(.red).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(!camera.isReady || camera.isProcessing)
    }

    private func requestReviewIfAppropriate() {
        guard ReviewPromptPolicy.shouldRequest(
            successfulSaveCount: successfulSaveCount,
            lastPromptedVersion: lastReviewPromptedVersion.isEmpty ? nil : lastReviewPromptedVersion,
            currentVersion: AppVersion.current
        ) else { return }
        lastReviewPromptedVersion = AppVersion.current
        requestReview()
    }

    private static func makeThumbnail(for url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image.map(UIImage.init(cgImage:)))
            }
        }
    }

    private static func loadLatestVideo() async -> (thumbnail: UIImage?, url: URL?) {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized || status == .limited else { return (nil, nil) }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .video, options: options).firstObject else { return (nil, nil) }
        let thumbnail = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let imageOptions = PHImageRequestOptions()
            imageOptions.isSynchronous = true
            imageOptions.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 120, height: 120), contentMode: .aspectFill, options: imageOptions) { image, _ in
                continuation.resume(returning: image)
            }
        }
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
        return (thumbnail, url)
    }
}

private struct AlbumThumbnailButton: View {
    let thumbnail: UIImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                else { Image(systemName: "photo.on.rectangle").font(.title2) }
            }
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.55)).clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
        }
    }
}

private struct VideoPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .offset(y: offset)
                .gesture(DragGesture().onChanged { value in
                    if value.translation.height > 0 { offset = value.translation.height }
                }.onEnded { value in
                    if value.translation.height > 120 { dismiss() }
                    else { withAnimation(.spring()) { offset = 0 } }
                })
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 18).padding(.trailing, 18)
        }
    }
}

private struct SettingsView: View {
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("saveComposite") private var saveComposite = true
    @AppStorage("saveFront") private var saveFront = false
    @AppStorage("saveRear") private var saveRear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("录制") {
                    Picker("默认布局", selection: $captureLayout) {
                        ForEach(CaptureLayout.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("默认主摄像头", selection: $primaryCamera) {
                        Text("后置").tag("rear")
                        Text("前置").tag("front")
                    }
                }
                Section("保存到照片图库") {
                    Toggle("合成视频", isOn: $saveComposite)
                    Toggle("前摄独立视频", isOn: $saveFront)
                    Toggle("后摄独立视频", isOn: $saveRear)
                    if !saveComposite && !saveFront && !saveRear {
                        Text("至少选择一种视频").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    Link("去 App Store 评分", destination: AppStoreUpdateChecker.writeReviewURL)
                }
            }
            .navigationTitle("设置")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
