import Foundation

/// Lightweight on-device diagnostics for reproducing recording failures.
/// The log is stored in the app's Documents directory so it is visible in the
/// Files app when file sharing is enabled.
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "com.dualcapture.debug-log")
    private let fileURL: URL
    private let formatter = ISO8601DateFormatter()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("dual_capture_debug.log")
        queue.sync {
            let header = "\n=== DualCapture session \(formatter.string(from: Date())) ===\n"
            try? header.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    func log(_ message: String) {
        queue.async { [fileURL, formatter] in
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
