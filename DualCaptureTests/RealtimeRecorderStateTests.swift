import XCTest
@testable import DualCapture

final class RealtimeRecorderStateTests: XCTestCase {
    func testRecorderOnlyAcceptsSamplesWhileRecording() {
        var recorder = RealtimeRecordingStateMachine()

        XCTAssertFalse(recorder.acceptsSamples)
        recorder.start()
        XCTAssertTrue(recorder.acceptsSamples)
        recorder.beginFinishing()
        XCTAssertFalse(recorder.acceptsSamples)
        XCTAssertEqual(recorder.state, .finishing)
    }

    func testRecorderCannotRestartWhileFinishing() {
        var recorder = RealtimeRecordingStateMachine()

        recorder.start()
        recorder.beginFinishing()
        recorder.start()

        XCTAssertEqual(recorder.state, .finishing)
    }

    func testRealtimePipelineProducesOneFinalFileAndNoPostProcessing() {
        let plan = RecordingPipelinePlan.realtimeComposite

        XCTAssertEqual(plan.outputFileCount, 1)
        XCTAssertFalse(plan.requiresPostProcessing)
        XCTAssertFalse(plan.supportsIndependentCameraFiles)
    }
}
