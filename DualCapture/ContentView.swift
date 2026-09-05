import SwiftUI
import UIKit
import AVKit
import Photos
import StoreKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @Environment(\.openURL) private var openURL
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("successfulSaveCount") private var successfulSaveCount = 0
    @AppStorage("lastReviewPromptedVersion") private var lastReviewPromptedVersion = ""
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var recordingStartedAt: Date?
    @State private var latestVideoURL: URL?
    @State private var latestThumbnail: UIImage?
    @State private var genieThumbnail: UIImage?
    @State private var genieProgress: CGFloat = 0
    @State private var showGenieAnimation = false
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
            if showGenieAnimation, let genieThumbnail {
                GenieSaveAnimation(image: genieThumbnail, progress: genieProgress)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
        .task {
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
                recordingStartedAt = nil
                guard let videoURL = await camera.stopRecording() else { return }
                if await camera.save(videoURL: videoURL) {
                    latestVideoURL = videoURL
                    successfulSaveCount += 1
                    let thumbnail = await Self.makeThumbnail(for: videoURL)
                    await playSaveAnimation(with: thumbnail)
                }
            }
        } else {
            recordingStartedAt = Date()
            camera.startRecording(layout: layout, primarySide: primarySide)
        }
    }

    @MainActor
    private func playSaveAnimation(with thumbnail: UIImage?) async {
        guard let thumbnail else { return }
        genieThumbnail = thumbnail
        genieProgress = 0
        showGenieAnimation = true
        await Task.yield()
        withAnimation(.easeInOut(duration: 0.65)) {
            genieProgress = 1
        }
        try? await Task.sleep(for: .milliseconds(700))
        latestThumbnail = thumbnail
        showGenieAnimation = false
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
        ), let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        lastReviewPromptedVersion = AppVersion.current
        SKStoreReviewController.requestReview(in: scene)
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

private struct GenieSaveAnimation: View {
    let image: UIImage
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let target = CGPoint(x: width / 2 - 153, y: height - 70)
            let startCenter = CGPoint(x: width / 2, y: height * 0.46)
            let center = CGPoint(
                x: startCenter.x + (target.x - startCenter.x) * progress,
                y: startCenter.y + (target.y - startCenter.y) * progress
            )
            let imageWidth = width * (1 - 0.92 * progress)
            let imageHeight = height * 0.68 * (1 - 0.94 * progress)

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: max(12, imageWidth), height: max(18, imageHeight))
                .clipShape(GenieShape(progress: progress))
                .position(center)
                .opacity(1 - max(0, progress - 0.9) / 0.1)
        }
    }
}

private struct GenieShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let bottomPhase = min(p / 0.55, 1)
        let fullPhase = max(0, (p - 0.35) / 0.65)
        let bottomInset = rect.width * 0.42 * bottomPhase
        let topInset = rect.width * 0.49 * fullPhase
        let topY = rect.height * 0.48 * fullPhase
        let bottomY = rect.height - rect.height * 0.55 * bottomPhase

        var path = Path()
        path.move(to: CGPoint(x: topInset, y: topY))
        path.addLine(to: CGPoint(x: rect.width - topInset, y: topY))
        path.addLine(to: CGPoint(x: rect.width - bottomInset, y: bottomY))
        path.addLine(to: CGPoint(x: bottomInset, y: bottomY))
        path.closeSubpath()
        return path
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
                Section("保存") {
                    Text("录制完成后自动保存合成视频到照片图库")
                        .foregroundStyle(.secondary)
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
