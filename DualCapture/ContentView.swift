import SwiftUI
import UIKit
import Photos

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("captureLayout") private var captureLayout = CaptureLayout.pictureInPicture.rawValue
    @AppStorage("primaryCamera") private var primaryCamera = "rear"
    @AppStorage("saveComposite") private var saveComposite = true
    @AppStorage("saveFront") private var saveFront = true
    @AppStorage("saveRear") private var saveRear = true
    @State private var recordingComposition: CaptureComposition?
    @State private var showSettings = false
    @State private var showSavedAlert = false
    @State private var recordingStartedAt: Date?

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
                    AlbumThumbnailButton(action: openAlbum)
                    Button(action: switchCamera) {
                        Image(systemName: "camera.rotate").font(.title2)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.55)).clipShape(Circle())
                    }
                    Button(action: toggleRecording) {
                        let shape = RoundedRectangle(cornerRadius: camera.isRecording ? 14 : 36)
                        shape.fill(camera.isRecording ? .red : .white).frame(width: 72, height: 72)
                            .overlay(shape.stroke(.white, lineWidth: 4).padding(-6))
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
        .alert("保存完成", isPresented: $showSavedAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("已将所选视频保存到照片图库。")
        }
    }

    private func toggleRecording() {
        if camera.isRecording {
            Task {
                guard let composition = recordingComposition else { return }
                recordingStartedAt = nil
                guard let files = await camera.stopRecording(layout: composition.layout, primarySide: composition.primarySide) else { return }
                let selection = SaveSelection(composite: saveComposite, front: saveFront, rear: saveRear)
                if await camera.save(files: files, selection: selection) { showSavedAlert = true }
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

    private func openAlbum() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }
}

private struct AlbumThumbnailButton: View {
    let action: () -> Void
    @State private var thumbnail: UIImage?

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
        .task { thumbnail = await Self.loadLatestVideoThumbnail() }
    }

    private static func loadLatestVideoThumbnail() async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .video, options: options).firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 120, height: 120), contentMode: .aspectFill, options: nil) { image, _ in
                continuation.resume(returning: image)
            }
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
