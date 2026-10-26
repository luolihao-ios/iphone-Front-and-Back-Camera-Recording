import Foundation

struct DiagnosticLogSnapshot {
    let text: String
    let fileURL: URL
}

/// 日志在 Documents 自动落盘；导出时排在所有待写消息之后，错误会展示给用户。
final class DebugLog {
    static let shared = DebugLog(directoryURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)

    private let queue = DispatchQueue(label: "com.dualcapture.debug-log")
    private let fileURL: URL
    private let formatter = ISO8601DateFormatter()
    private var lastWriteError: Error?

    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent("dual_capture_debug.log")
        queue.sync {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "未知"
            let build = info["CFBundleVersion"] as? String ?? "未知"
            let sdk = info["DTSDKName"] as? String ?? "未知"
            do {
                try append("\n=== 同框之外 \(version) (\(build)) SDK=\(sdk) \(formatter.string(from: Date())) ===\n")
            } catch { lastWriteError = error }
        }
    }

    func log(_ message: String) {
        queue.async {
            do {
                if let previousError = self.lastWriteError {
                    try self.append("diagnostics.storage_recovered previous_error=\(previousError.localizedDescription)\n")
                }
                try self.append("[\(self.formatter.string(from: Date()))] \(message)\n")
                self.lastWriteError = nil
            } catch { self.lastWriteError = error }
        }
    }

    func snapshot() async throws -> DiagnosticLogSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.append("[\(self.formatter.string(from: Date()))] diagnostics.snapshot.request\n")
                    if let previousError = self.lastWriteError {
                        try self.append("diagnostics.storage_recovered previous_error=\(previousError.localizedDescription)\n")
                        self.lastWriteError = nil
                    }
                    let text = try String(contentsOf: self.fileURL, encoding: .utf8)
                    let directory = self.fileURL.deletingLastPathComponent().appendingPathComponent("诊断日志", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let exportURL = directory.appendingPathComponent("同框之外-诊断日志.log")
                    try Data(text.utf8).write(to: exportURL, options: .atomic)
                    continuation.resume(returning: DiagnosticLogSnapshot(text: text, fileURL: exportURL))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func append(_ text: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
