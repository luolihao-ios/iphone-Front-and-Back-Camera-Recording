import XCTest
@testable import DualCapture

final class DiagnosticLogTests: XCTestCase {
    func testInstalledAppActuallyExposesDocumentsToFiles() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true,
            "工程里写了构建变量不代表最终 Info.plist 有这个键；必须验证安装包")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
    }

    func testLoggerCreatesMissingDirectoryAndExportsAllQueuedMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DebugLog(directoryURL: root.appendingPathComponent("Documents"))
        logger.log("save.success")
        logger.log("save.animation.skipped thumbnail_missing")
        let snapshot = try await logger.snapshot()
        XCTAssertTrue(snapshot.text.contains("save.success"))
        XCTAssertTrue(snapshot.text.contains("thumbnail_missing"))
        XCTAssertEqual(snapshot.fileURL.pathExtension, "log")
        XCTAssertEqual(try String(contentsOf: snapshot.fileURL, encoding: .utf8), snapshot.text)
    }

    func testReopeningAppDoesNotErasePreviousRecordingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSession = DebugLog(directoryURL: root)
        firstSession.log("previous_recording_saved")
        _ = try await firstSession.snapshot()
        let secondSession = DebugLog(directoryURL: root)
        secondSession.log("next_app_launch")
        let snapshot = try await secondSession.snapshot()
        XCTAssertTrue(snapshot.text.contains("previous_recording_saved"))
        XCTAssertTrue(snapshot.text.contains("next_app_launch"))
    }

    func testExportReportsStorageFailureRatherThanOfferingNonexistentFile() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let logger = DebugLog(directoryURL: blockedDirectory)
        logger.log("must_not_silently_disappear")
        do {
            _ = try await logger.snapshot()
            XCTFail("写入失败时必须在诊断页面明确报告错误")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testTemporaryWriteFailureRemainsVisibleAfterStorageRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = DebugLog(directoryURL: root)
        _ = try await logger.snapshot()
        let logURL = root.appendingPathComponent("dual_capture_debug.log")
        let backup = root.appendingPathComponent("before-failure.log")
        try FileManager.default.moveItem(at: logURL, to: backup)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        logger.log("write_fails_because_file_became_directory")
        do {
            _ = try await logger.snapshot()
            XCTFail("故意制造的文件错误应当被报告")
        } catch { }
        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.moveItem(at: backup, to: logURL)
        logger.log("recording_after_recovery")
        let snapshot = try await logger.snapshot()
        XCTAssertTrue(snapshot.text.contains("diagnostics.storage_recovered"), "日志丢过一条不能假装完整")
        XCTAssertTrue(snapshot.text.contains("recording_after_recovery"))
    }
}
