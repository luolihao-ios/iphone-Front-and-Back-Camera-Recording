import SwiftUI
import UIKit
import AVKit
import Photos
import StoreKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("smallWindowShape") private var smallWindowShape = SmallWindowShape.roundedRectangle.rawValue
    @AppStorage("smallWindowScale") private var smallWindowScale = 1.0
    @AppStorage("smallWindowCenterX") private var smallWindowCenterX = 0.19
    @AppStorage("smallWindowCenterY") private var smallWindowCenterY = 0.20
    @AppStorage("compositionGridEnabled") private var gridEnabled = false
    @AppStorage("successfulSaveCount") private var successfulSaveCount = 0
    @AppStorage("lastReviewPromptedVersion") private var lastReviewPromptedVersion = ""
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var recordingStartedAt: Date?
    @State private var latestVideoURL: URL?
    @State private var latestThumbnail: UIImage?
    @State private var latestPhoto: UIImage?
    @State private var mode = CaptureMode.video
    @State private var showWindowControls = false
    @State private var previewSize = CGSize(width: 390, height: 844)
    @State private var recordingConfiguration: RealtimeRecordingConfiguration?
    @State private var handlingCapture = false
    @State private var saveAnimationDestination = SaveAnimationDestination()
    @State private var genieThumbnail: UIImage?
    @State private var showGenieAnimation = false

    private var layout: CaptureLayout { CaptureLayout(rawValue: captureLayout) ?? .pictureInPicture }
    private var primarySide: CameraSide { primaryCamera == "front" ? .front : .rear }
    private var configuration: RealtimeRecordingConfiguration {
        RealtimeRecordingConfiguration(layout: layout, primarySide: primarySide,
            renderSize: RealtimeRecordingConfiguration.renderSize(for: previewSize),
            pictureInPicture: .init(shape: SmallWindowShape(rawValue: smallWindowShape) ?? .roundedRectangle,
                scale: smallWindowScale, center: CGPoint(x: smallWindowCenterX, y: smallWindowCenterY)))
    }
    private var busy: Bool { handlingCapture || camera.isProcessing || showGenieAnimation }

    var body: some View {
        GeometryReader { viewport in
          ZStack {
            Color.black.ignoresSafeArea()
            cameraSurface
            captureControls
                .frame(width: min(520, max(0, viewport.size.width - 24)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            shortcuts(availableSize: viewport.size)
            if showGenieAnimation, let genieThumbnail, let target = saveAnimationDestination.activeFrame {
                GenieSaveAnimation(image: genieThumbnail, target: target) {
                    latestThumbnail = genieThumbnail
                    showGenieAnimation = false
                    saveAnimationDestination.end()
                }
            }
          }
          .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .coordinateSpace(name: "cameraScreen")
        .onPreferenceChange(AlbumFramePreference.self) { saveAnimationDestination.update($0) }
        .task {
            await camera.prepare()
            let latest = await Self.loadLatestVideo()
            if latestVideoURL == nil && latestPhoto == nil {
                latestThumbnail = latest.thumbnail
                latestVideoURL = latest.url
                latestPhoto = latest.photo
            }
            try? await Task.sleep(for: .seconds(2))
            requestReviewIfAppropriate()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showPlayer) {
            if let latestVideoURL { VideoPlayerView(url: latestVideoURL) }
            else if let latestPhoto { PhotoViewer(image: latestPhoto) }
        }
        .alert("无法完成操作", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("好", role: .cancel) { camera.errorMessage = nil }
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var cameraSurface: some View {
        GeometryReader { proxy in
            if camera.isSupported {
                CameraPreview(camera: camera, configuration: recordingConfiguration ?? configuration) { center in
                    guard !camera.isRecording, !busy else { return }
                    smallWindowCenterX = center.x
                    smallWindowCenterY = center.y
                }
            }
            if gridEnabled { CompositionGrid() }
            Color.clear.allowsHitTesting(false)
                .onAppear { updateViewport(proxy.size) }
                .onChange(of: proxy.size) { _, size in updateViewport(size) }
        }
        .ignoresSafeArea()
    }

    private var captureControls: some View {
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
            } else if !busy {
                Button(action: camera.toggleTorch) {
                    Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(camera.isTorchOn ? .yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.28), in: Circle())
                }
                .disabled(!camera.hasTorch)
                .accessibilityLabel(camera.isTorchOn ? "关闭补光灯" : "开启补光灯")
            }
            Spacer()
            ZStack(alignment: .bottom) {
                // 保留相册按钮的布局与目标测量，录制时只隐藏，不移除锚点。
                idleCaptureControls
                .disabled(busy || camera.isRecording)
                .opacity(camera.isRecording ? 0 : 1)
                .accessibilityHidden(camera.isRecording)
                .padding(.bottom, 20)
                if camera.isRecording {
                    recordButton()
                        .disabled(camera.isProcessing)
                        .padding(.bottom, 34)
                }
            }
        }
    }

    private var idleCaptureControls: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(spacing: 5) {
                    AlbumThumbnailButton(thumbnail: latestThumbnail) {
                        showPlayer = latestVideoURL != nil || latestPhoto != nil
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: AlbumFramePreference.self, value: proxy.frame(in: .named("cameraScreen")))
                    })
                    Text("相册").font(.caption).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                recordButton()
                VStack(spacing: 5) {
                    Button(action: switchCamera) {
                        Image(systemName: "camera.rotate").font(.title2)
                            .frame(width: 50, height: 50)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel("切换主摄像头")
                    Text("旋转").font(.caption)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 4) {
                ForEach(CaptureMode.allCases, id: \.self) { item in
                    Button { mode = item } label: {
                        Text(item.rawValue).font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .foregroundStyle(mode == item ? .white : .white.opacity(0.65))
                            .background(mode == item ? .white.opacity(0.22) : .clear, in: Capsule())
                    }
                    .accessibilityAddTraits(mode == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.black.opacity(0.4), in: Capsule())
        }
    }

    @ViewBuilder
    private func shortcuts(availableSize: CGSize) -> some View {
        if !camera.isRecording, !busy {
            HStack {
                Spacer()
                CameraShortcutMenu(layout: layout, gridEnabled: $gridEnabled,
                    maximumHeight: max(110, min(442, availableSize.height - 250)),
                    onSelectLayout: { selected in captureLayout = selected.rawValue; showWindowControls = false },
                    onWindowSettings: { captureLayout = CaptureLayout.pictureInPicture.rawValue; showWindowControls.toggle() },
                    onSettings: { showSettings = true })
            }
            .padding(.trailing, 10)
            .padding(.top, availableSize.height < 500 ? 8 : 60)
            .padding(.bottom, availableSize.height < 500 ? 158 : 190)
            if showWindowControls {
                VStack {
                    Spacer()
                    SmallWindowPanel(shape: $smallWindowShape, scale: $smallWindowScale) { showWindowControls = false }
                    Spacer().frame(height: 180)
                }
            }
        }
    }

    private func updateViewport(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if size != previewSize, showGenieAnimation {
            // 旋转或折叠后旧目标坐标已失效，立即收尾而不是向屏幕外吸入。
            latestThumbnail = genieThumbnail
            showGenieAnimation = false
            saveAnimationDestination.end()
            DebugLog.shared.log("save.animation.cancelled viewport_changed from=\(previewSize) to=\(size)")
        }
        previewSize = size
        DebugLog.shared.log("viewport.changed size=\(size) recording=\(camera.isRecording)")
    }

    @MainActor
    private func toggleRecording() {
        guard !busy else { return }
        showWindowControls = false
        if camera.isRecording {
            handlingCapture = true
            Task {
                defer { handlingCapture = false; recordingConfiguration = nil }
                recordingStartedAt = nil
                guard let videoURL = await camera.stopRecording() else { return }
                if await camera.save(videoURL: videoURL) {
                    latestVideoURL = videoURL
                    latestPhoto = nil
                    successfulSaveCount += 1
                    let thumbnail = await Self.makeThumbnail(for: videoURL)
                    await playSaveAnimation(with: thumbnail)
                }
            }
        } else if mode == .photo {
            handlingCapture = true
            let capturedConfiguration = configuration
            Task {
                defer { handlingCapture = false }
                if let image = await camera.takePhoto(configuration: capturedConfiguration) {
                    latestVideoURL = nil
                    latestPhoto = image
                    successfulSaveCount += 1
                    await playSaveAnimation(with: image)
                }
            }
        } else {
            let capturedConfiguration = configuration
            camera.startRecording(configuration: capturedConfiguration)
            if camera.isRecording {
                recordingConfiguration = capturedConfiguration
                recordingStartedAt = Date()
            }
        }
    }

    @MainActor
    private func playSaveAnimation(with thumbnail: UIImage?) async {
        guard let thumbnail else { return }
        guard let target = saveAnimationDestination.begin() else {
            DebugLog.shared.log("save.animation.skipped no_valid_album_destination")
            latestThumbnail = thumbnail
            return
        }
        DebugLog.shared.log("save.animation.begin album_destination=\(target)")
        genieThumbnail = thumbnail
        showGenieAnimation = true
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
                    Circle().fill(mode == .photo ? .white : .red).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(!camera.isReady || camera.isProcessing)
        .buttonStyle(.plain)
        .accessibilityLabel(camera.isRecording ? "停止录制" : (mode == .photo ? "拍照" : "开始录制"))
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

    private static func loadLatestVideo() async -> (thumbnail: UIImage?, url: URL?, photo: UIImage?) {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized || status == .limited else { return (nil, nil, nil) }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return (nil, nil, nil) }
        let thumbnail = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let imageOptions = PHImageRequestOptions()
            imageOptions.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: imageOptions) { image, info in
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                continuation.resume(returning: image)
            }
        }
        guard asset.mediaType == .video else { return (thumbnail, nil, thumbnail) }
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
        return (thumbnail, url, nil)
    }
}

private struct AlbumFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct PhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: offset)
                .gesture(DragGesture().onChanged { offset = max(0, $0.translation.height) }
                    .onEnded { value in
                        if value.translation.height > 120 { dismiss() }
                        else { withAnimation(.spring()) { offset = 0 } }
                    })
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
            .accessibilityLabel("返回相机")
        }
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
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("查看最新照片或视频")
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
    @Environment(\.openURL) private var openURL
    @State private var availableUpdate: AppStoreUpdate?
    @State private var isCheckingUpdate = false

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
                    Button {
                        guard let availableUpdate else { return }
                        openURL(availableUpdate.storeURL)
                    } label: {
                        HStack {
                            Text("版本")
                            Spacer()
                            if isCheckingUpdate {
                                ProgressView()
                                    .controlSize(.small)
                            } else if availableUpdate != nil {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("有新版本可更新")
                            }
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(availableUpdate == nil)
                    Link("去 App Store 评分", destination: AppStoreUpdateChecker.writeReviewURL)
                }
            }
            .navigationTitle("设置")
            .task {
                isCheckingUpdate = true
                availableUpdate = await AppStoreUpdateChecker.fetchAvailableUpdate(installedVersion: AppVersion.current)
                isCheckingUpdate = false
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
