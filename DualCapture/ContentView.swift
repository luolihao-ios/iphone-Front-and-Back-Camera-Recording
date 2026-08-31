import SwiftUI
import UIKit
import AVKit

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("saveComposite") private var saveComposite = true
    @AppStorage("saveFront") private var saveFront = true
    @AppStorage("saveRear") private var saveRear = true
    @State private var recordingComposition: CaptureComposition?
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var recordingStartedAt: Date?
    @State private var latestVideoURL: URL?
    @State private var latestThumbnail: UIImage?

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
                            Circle().fill(.red).frame(width: 9, height: 9)
                            Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        }
                        .font(.system(.headline, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7)).clipShape(Capsule())
                    }
                } else if camera.isProcessing {
                    ProgressView("正在处理录制…")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                HStack(spacing: 22) {
                    AlbumThumbnailButton(thumbnail: latestThumbnail) { showPlayer = latestVideoURL != nil }
                    Button(action: switchCamera) {
                        Image(systemName: "camera.rotate").font(.title2)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.55)).clipShape(Circle())
                    }
                    Button(action: toggleRecording) {
                        ZStack {
                            Circle().fill(.white).frame(width: 72, height: 72)
                                .overlay(Circle().stroke(.white, lineWidth: 4).padding(-6))
                            if camera.isRecording {
                                RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(.red).frame(width: 58, height: 58)
                            }
                        }
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.title2)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.55)).clipShape(Circle())
                    }
                }
                .disabled(camera.isProcessing)
                .padding(.bottom, 34)
            }
        }
        .task { await camera.prepare() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPlayer) {
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

    private static func makeThumbnail(for url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image.map(UIImage.init(cgImage:)))
            }
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
            .frame(width: 54, height: 54)
            .background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.6), lineWidth: 1))
        }
    }
}

private struct VideoPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("最近录制")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("saveComposite") private var saveComposite = true
    @AppStorage("saveFront") private var saveFront = true
    @AppStorage("saveRear") private var saveRear = true

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
            }
            .navigationTitle("设置")
        }
    }
}
