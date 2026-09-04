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
}
