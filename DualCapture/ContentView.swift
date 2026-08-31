import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var layout: CaptureLayout = .pictureInPicture
    @State private var primarySide: CameraSide = .rear
    @State private var recordingComposition: CaptureComposition?
    @State private var files: RecordingFiles?
    @State private var selection = SaveSelection()
    @State private var showSaveSheet = false
    @State private var showSavedAlert = false
    @State private var recordingStartedAt: Date?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.isSupported {
                CameraPreview(camera: camera, layout: layout, primarySide: primarySide) { side in
                    guard !camera.isRecording, side != primarySide else { return }
                    primarySide = side
                }
                    .ignoresSafeArea()
            }
            VStack(spacing: 16) {
                if camera.isRecording, let recordingStartedAt {
                    TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(recordingStartedAt)))
                        Text(String(format: "正在录制  %d:%02d", elapsed / 60, elapsed % 60))
                            .font(.system(.headline, design: .monospaced))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.red.opacity(0.9)).clipShape(Capsule())
                    }
                } else if camera.isProcessing {
                    ProgressView("正在处理录制…")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let message = camera.statusMessage {
                    Text(message).multilineTextAlignment(.center).padding().background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                Picker("布局", selection: $layout) {
                    ForEach(CaptureLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).disabled(camera.isRecording)
                if !camera.isRecording { Text("点击画面可交换主次") }
                Button(action: toggleRecording) {
                    let shape = RoundedRectangle(cornerRadius: camera.isRecording ? 14 : 36)
                    shape.fill(camera.isRecording ? .red : .white).frame(width: 72, height: 72)
                        .overlay(shape.stroke(.white, lineWidth: 4).padding(-6))
                }
                .disabled(!camera.isReady || camera.isProcessing)
                .padding(.bottom, 34)
            }
            .foregroundStyle(.white)
        }
        .task { await camera.prepare() }
        .sheet(isPresented: $showSaveSheet) {
            SaveSheet(selection: $selection) {
                guard let files else { return }
                Task {
                    let saved = await camera.save(files: files, selection: selection)
                    showSaveSheet = false
                    if saved { showSavedAlert = true }
                }
            }
        }
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
                files = await camera.stopRecording(layout: composition.layout, primarySide: composition.primarySide)
                if files != nil { showSaveSheet = true }
            }
        } else {
            recordingComposition = CaptureComposition(layout: layout, primarySide: primarySide)
            recordingStartedAt = Date()
            selection = SaveSelection()
            camera.startRecording()
        }
    }
}

private struct SaveSheet: View {
    @Binding var selection: SaveSelection
    let save: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46)).foregroundStyle(.green)
                Text("录制完成").font(.title2.bold())
                Text("选择要保存到照片图库的视频")
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    saveToggle("合成视频", systemImage: "rectangle.on.rectangle", isOn: $selection.composite)
                    Divider()
                    saveToggle("前摄独立视频", systemImage: "camera", isOn: $selection.front)
                    Divider()
                    saveToggle("后摄独立视频", systemImage: "camera.fill", isOn: $selection.rear)
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer()
            }
            .padding()
            .navigationTitle("保存录制结果")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!selection.composite && !selection.front && !selection.rear) } }
        }
    }

    private func saveToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
