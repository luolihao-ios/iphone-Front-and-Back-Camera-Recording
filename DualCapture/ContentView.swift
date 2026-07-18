import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var layout: CaptureLayout = .pictureInPicture
    @State private var primarySide: CameraSide = .rear
    @State private var recordingComposition: CaptureComposition?
    @State private var files: RecordingFiles?
    @State private var selection = SaveSelection()
    @State private var showSaveSheet = false

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
                if let message = camera.statusMessage {
                    Text(message).multilineTextAlignment(.center).padding().background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                Picker("布局", selection: $layout) {
                    ForEach(CaptureLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).disabled(camera.isRecording)
                if !camera.isRecording { Text("点击画面可交换主次") }
                Button(action: toggleRecording) {
                    Circle().fill(camera.isRecording ? .red : .white).frame(width: 72, height: 72)
                        .overlay(Circle().stroke(.white, lineWidth: 4).padding(-6))
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
                    await camera.save(files: files, selection: selection)
                    showSaveSheet = false
                }
            }
        }
    }

    private func toggleRecording() {
        if camera.isRecording {
            Task {
                guard let composition = recordingComposition else { return }
                files = await camera.stopRecording(layout: composition.layout, primarySide: composition.primarySide)
                if files != nil { showSaveSheet = true }
            }
        } else {
            recordingComposition = CaptureComposition(layout: layout, primarySide: primarySide)
            camera.startRecording()
        }
    }
}

private struct SaveSheet: View {
    @Binding var selection: SaveSelection
    let save: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("选择要保存到照片的文件") {
                    Toggle("合成视频", isOn: $selection.composite)
                    Toggle("前摄独立视频", isOn: $selection.front)
                    Toggle("后摄独立视频", isOn: $selection.rear)
                }
            }
            .navigationTitle("保存录制结果")
            .toolbar { Button("保存", action: save).disabled(!selection.composite && !selection.front && !selection.rear) }
        }
    }
}
