# 实时双摄合成录制 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实时合成前后摄并写入唯一最终视频，停止时不再导出整段视频。

**Architecture:** `AVCaptureMultiCamSession` 继续采集前、后摄与音频。新增 `RealtimeCompositeRecorder`：以主摄帧为输出节奏，使用 Core Image/Metal 把最近可用的副摄帧合成至 1080×1920 像素缓冲区，再直接写入一个 `AVAssetWriter`。`CameraManager` 只持有它，停止时仅结束同一个文件。

**Tech Stack:** Swift 5、SwiftUI、AVFoundation、Core Image、Metal、Photos、XCTest、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-09-04-realtime-dual-camera-recording-design.md`

## Global Constraints

- iOS 17.0+、竖屏 iPhone；1080×1920 H.264 `.mov` 和 AAC 音频。
- 一次录制只有一份合成视频，不提供前、后摄独立文件或保存选项。
- 画中画在右上角且有圆角；分屏严格上下各 1080×960；前置画面镜像。
- 性能不足时丢弃过期帧，绝不阻塞采样队列或 UI。
- 开始/结束提示音不写入视频；停止时不使用 `AVAssetExportSession`。
- 所有生产逻辑先测试失败，再写最小实现。

## File Structure

- Create `DualCapture/RealtimeCompositeRecorder.swift`: 单文件实时视频/音频写入、帧缓存和 GPU 合成。
- Modify `DualCapture/Models.swift`: 实时布局、帧配对、录制状态和单文件管线模型。
- Modify `DualCapture/CameraManager.swift`: 一个实时录制器替代两个原始录制器和后处理导出。
- Modify `DualCapture/ContentView.swift`: 删除独立保存开关，自动保存唯一最终 URL。
- Delete `DualCapture/MovieRecorder.swift` and `DualCapture/VideoComposer.swift`.
- Create `DualCaptureTests/RealtimeRecordingConfigurationTests.swift` and `DualCaptureTests/RealtimeRecorderStateTests.swift`.
- Modify `DualCaptureTests/VideoLayoutFramesTests.swift` and `README.md`.

## Task 1: Layout, pairing, and state models

**Files:** Modify `DualCapture/Models.swift`; create `DualCaptureTests/RealtimeRecordingConfigurationTests.swift`; modify `DualCaptureTests/VideoLayoutFramesTests.swift`.

**Interfaces:**

```swift
struct RealtimeRecordingConfiguration: Equatable {
    let layout: CaptureLayout
    let primarySide: CameraSide
    let renderSize: CGSize
}
struct RealtimeVideoFrames: Equatable {
    let primaryFrame: CGRect
    let secondaryFrame: CGRect
    let secondaryCornerRadius: CGFloat
}
enum RealtimeVideoLayout { static func frames(for: RealtimeRecordingConfiguration) -> RealtimeVideoFrames }
enum FramePairingPolicy { static func shouldWrite(primaryTime: Double, secondaryTime: Double?) -> Bool }
enum RealtimeRecordingState { case idle, recording, finishing, finished }
```

- [ ] **Step 1: Write failing tests**

```swift
func testSplitLayoutUsesTwoExactEqualHalves() {
    let frames = RealtimeVideoLayout.frames(for: .init(layout: .split, primarySide: .rear, renderSize: .init(width: 1080, height: 1920)))
    XCTAssertEqual(frames.primaryFrame, CGRect(x: 0, y: 0, width: 1080, height: 960))
    XCTAssertEqual(frames.secondaryFrame, CGRect(x: 0, y: 960, width: 1080, height: 960))
}
func testPictureInPictureUsesRightTopRoundedSecondaryFrame() {
    let frames = RealtimeVideoLayout.frames(for: .init(layout: .pictureInPicture, primarySide: .rear, renderSize: .init(width: 1080, height: 1920)))
    XCTAssertGreaterThan(frames.secondaryFrame.minX, 540)
    XCTAssertLessThan(frames.secondaryFrame.minY, 384)
    XCTAssertGreaterThan(frames.secondaryCornerRadius, 0)
}
func testFramePairingWaitsForSecondaryAndRejectsFutureFrame() {
    XCTAssertFalse(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: nil))
    XCTAssertFalse(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 1.1))
    XCTAssertTrue(FramePairingPolicy.shouldWrite(primaryTime: 1, secondaryTime: 0.99))
}
```

- [ ] **Step 2: Verify red**

Run `xcodegen generate` then `xcodebuild -project DualCapture.xcodeproj -scheme DualCapture -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DualCaptureTests/RealtimeRecordingConfigurationTests test`.

Expected: missing real-time types.

- [ ] **Step 3: Implement minimum model behavior**

Implement `RealtimeRecordingConfiguration` with default 1080×1920 size; make PIP use current `PictureInPictureMetrics`, full primary frame, and a nonzero corner radius. Make split use current `VideoLayoutFrames` exact 960-pixel halves. Make pairing return true only when secondary exists and `secondaryTime <= primaryTime`.

- [ ] **Step 4: Verify green**

Run the Step 2 command. Expected: all new layout/pairing tests pass.

- [ ] **Step 5: Commit**

Run `git add DualCapture/Models.swift DualCaptureTests/RealtimeRecordingConfigurationTests.swift DualCaptureTests/VideoLayoutFramesTests.swift` then `git commit -m "feat: define realtime recording layout"`.

## Task 2: Real-time composite recorder

**Files:** Create `DualCapture/RealtimeCompositeRecorder.swift`; create `DualCaptureTests/RealtimeRecorderStateTests.swift`.

**Interfaces:**

```swift
struct RealtimeRecordingStateMachine: Equatable {
    private(set) var state: RealtimeRecordingState
    var acceptsSamples: Bool { get }
    mutating func start()
    mutating func beginFinishing()
    mutating func finish()
}
final class RealtimeCompositeRecorder {
    init(url: URL, configuration: RealtimeRecordingConfiguration) throws
    func appendVideo(_ sample: CMSampleBuffer, side: CameraSide)
    func appendAudio(_ sample: CMSampleBuffer)
    func finish() async -> URL?
}
```

- [ ] **Step 1: Write failing state tests**

```swift
func testRecorderOnlyAcceptsSamplesWhileRecording() {
    var recorder = RealtimeRecordingStateMachine()
    XCTAssertFalse(recorder.acceptsSamples)
    recorder.start(); XCTAssertTrue(recorder.acceptsSamples)
    recorder.beginFinishing(); XCTAssertFalse(recorder.acceptsSamples)
    XCTAssertEqual(recorder.state, .finishing)
}
func testRecorderCannotRestartWhileFinishing() {
    var recorder = RealtimeRecordingStateMachine()
    recorder.start(); recorder.beginFinishing(); recorder.start()
    XCTAssertEqual(recorder.state, .finishing)
}
```

- [ ] **Step 2: Verify red**

Run `xcodegen generate` then `xcodebuild -project DualCapture.xcodeproj -scheme DualCapture -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DualCaptureTests/RealtimeRecorderStateTests test`.

Expected: missing `RealtimeRecordingStateMachine`.

- [ ] **Step 3: Implement state and writer**

Implement state transitions exactly as tested. Build the recorder with one `AVAssetWriter`, one H.264 video input, one AAC audio input, and `AVAssetWriterInputPixelBufferAdaptor` configured for 32BGRA at the configuration size. Both writer inputs set `expectsMediaDataInRealTime = true`.

Keep latest front/rear sample buffers. On a primary-side sample, require a nonfuture secondary sample, allocate one pixel buffer, and render to it through `CIContext(mtlDevice:)` when Metal exists, falling back to `CIContext(options: nil)`. Aspect-fill both images; mirror front with X transform; for PIP, use a Core Image rounded-rectangle mask on the right-top secondary frame. Append at the primary timestamp only when video input is ready. Start writing/session at first successful video append. Ignore audio before it starts; append audio to only this writer afterwards. `finish()` must change state to finishing, mark both inputs finished, await `finishWriting`, set finished, and return URL only for `.completed`.

- [ ] **Step 4: Verify green**

Run Task 2 Step 2 command. Expected: state tests pass.

- [ ] **Step 5: Commit**

Run `git add DualCapture/RealtimeCompositeRecorder.swift DualCaptureTests/RealtimeRecorderStateTests.swift` then `git commit -m "feat: add realtime composite recorder"`.

## Task 3: Replace the existing two-file CameraManager pipeline

**Files:** Modify `DualCapture/CameraManager.swift` and `DualCapture/Models.swift`; delete `DualCapture/MovieRecorder.swift` and `DualCapture/VideoComposer.swift`; modify `DualCaptureTests/RealtimeRecorderStateTests.swift`.

**Interfaces:**

```swift
struct RecordingPipelinePlan: Equatable {
    let outputFileCount: Int
    let requiresPostProcessing: Bool
    let supportsIndependentCameraFiles: Bool
    static let realtimeComposite: RecordingPipelinePlan
}
func startRecording(layout: CaptureLayout, primarySide: CameraSide)
func stopRecording() async -> URL?
func save(videoURL: URL) async -> Bool
```

- [ ] **Step 1: Write failing pipeline test**

```swift
func testRealtimePipelineProducesOneFinalFileAndNoPostProcessing() {
    let plan = RecordingPipelinePlan.realtimeComposite
    XCTAssertEqual(plan.outputFileCount, 1)
    XCTAssertFalse(plan.requiresPostProcessing)
    XCTAssertFalse(plan.supportsIndependentCameraFiles)
}
```

- [ ] **Step 2: Verify red**

Run Task 2 Step 2 command. Expected: missing `RecordingPipelinePlan`.

- [ ] **Step 3: Implement replacement path**

Implement `realtimeComposite` as `(1, false, false)`. Replace `frontRecorder` and `rearRecorder` with one `realtimeRecorder`. Create a unique temporary `final.mov` in `startRecording(layout:primarySide:)`; pass all video samples to it while preserving `previewSink`; pass delayed audio to it after the existing one-second prompt-sound exclusion. In `stopRecording()`, set `isProcessing` and status “正在完成录制…”, await only `realtimeRecorder.finish()`, clear processing in all outcomes, and report “视频写入失败，请重试。” on failure. `save(videoURL:)` must call `PhotoLibrarySaver.save([videoURL])`.

Remove `finishRecorders`, `RecordingFiles`, `SaveSelection`, `MovieRecorder.swift`, and `VideoComposer.swift` after callers compile.

- [ ] **Step 4: Verify green**

Run `xcodegen generate` then `xcodebuild -project DualCapture.xcodeproj -scheme DualCapture -destination 'platform=iOS Simulator,name=iPhone 16' test`.

Expected: all existing and new tests pass.

- [ ] **Step 5: Commit**

Run `git add DualCapture/CameraManager.swift DualCapture/Models.swift DualCaptureTests/RealtimeRecorderStateTests.swift`, `git rm DualCapture/MovieRecorder.swift DualCapture/VideoComposer.swift`, then `git commit -m "refactor: record realtime composite video"`.

## Task 4: Simplify saving UI

**Files:** Modify `DualCapture/ContentView.swift`; modify `DualCaptureTests/RealtimeRecordingConfigurationTests.swift`.

- [ ] **Step 1: Add permanent save-mode regression test**

```swift
func testRealtimePipelineHasNoIndependentSaveModes() {
    XCTAssertFalse(RecordingPipelinePlan.realtimeComposite.supportsIndependentCameraFiles)
}
```

- [ ] **Step 2: Verify the test passes after Task 3**

Run Task 3 Step 4 command. Expected: all tests pass.

- [ ] **Step 3: Update ContentView**

Remove `saveComposite`, `saveFront`, `saveRear`, and `saveSettingsInitialized`. Start with `camera.startRecording(layout: layout, primarySide: primarySide)`. Stop/save with:

```swift
guard let videoURL = await camera.stopRecording() else { return }
if await camera.save(videoURL: videoURL) {
    latestVideoURL = videoURL
    latestThumbnail = await Self.makeThumbnail(for: videoURL)
}
```

Replace three settings toggles with `Section("保存") { Text("录制完成后自动保存合成视频到照片图库").foregroundStyle(.secondary) }`. Keep thumbnail/player behavior. Keep the current white-background black-text processing presentation, changing text to “正在完成录制…”.

- [ ] **Step 4: Verify green**

Run Task 3 Step 4 command. Expected: all tests pass.

- [ ] **Step 5: Commit**

Run `git add DualCapture/ContentView.swift DualCaptureTests/RealtimeRecordingConfigurationTests.swift` then `git commit -m "feat: simplify realtime video saving UI"`.

## Task 5: Documentation and full verification

**Files:** Modify `README.md`.

- [ ] **Step 1: Update user-facing recording description**

Add: `录制期间会实时合成前后摄画面，并直接写入一个最终视频。停止录制后应用仅完成该文件写入并自动保存到照片图库；不会再进行整段视频二次合成。`

Add device acceptance checks: 10 秒、1 分钟、2 分钟的画中画和分屏；确认停止速度、画中画圆角位置、前置镜像、音频和预览一致。

- [ ] **Step 2: Confirm old architecture is absent**

Run `rg -n "MovieRecorder|VideoComposer|SaveSelection|RecordingFiles|saveFront|saveRear" DualCapture DualCaptureTests`.

Expected: no matches.

- [ ] **Step 3: Run broad verification**

Run:

```bash
xcodegen generate
xcodebuild -project DualCapture.xcodeproj -scheme DualCapture -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project DualCapture.xcodeproj -scheme DualCapture -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Push and confirm GitHub Actions `Build unsigned IPA` finishes device build, tests, IPA packaging, and artifact upload.

- [ ] **Step 4: Commit**

Run `git add README.md` then `git commit -m "docs: describe realtime composite recording"`.

- [ ] **Step 5: Device acceptance before App Store upload**

Install a signed test IPA. Test both layouts at 10 seconds, 1 minute, and 2 minutes; record build number, stop-to-save duration, final layout, audio, preview consistency, and dropped-frame artifacts. Do not upload to App Store Connect until the user confirms device acceptance.

## Self-review

- Spec coverage: Tasks 1–2 define and implement real-time frame processing; Task 3 removes the two-file/post-export path; Task 4 removes independent save UI; Task 5 validates long recordings and documents behavior.
- Placeholder scan: no unresolved work markers exist.
- Type consistency: each consumed model/API is defined in an earlier task using the same signature.
