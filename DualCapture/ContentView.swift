import SwiftUI

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
                HStack {
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill").font(.title2).padding(12)
                    }
                    .disabled(camera.isRecording || camera.isProcessing)
                }
                .padding(.top, 10).padding(.horizontal)
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
                if !camera.isRecording && !camera.isProcessing {
                    Text("点击画面可交换主次").foregroundStyle(.white.opacity(0.8))
                }
                Button(action: toggleRecording) {
                    let shape = RoundedRectangle(cornerRadius: camera.isRecording ? 14 : 36)
                    shape.fill(camera.isRecording ? .red : .white).frame(width: 72, height: 72)
                        .overlay(shape.stroke(.white, lineWidth: 4).padding(-6))
                }
                .disabled(!camera.isReady || camera.isProcessing)
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
