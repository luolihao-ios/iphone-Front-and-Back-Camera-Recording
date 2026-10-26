import XCTest
import SwiftUI
@testable import DualCapture

final class AlbumTargetIntegrationTests: XCTestCase {
    @MainActor
    func testActualCaptureScreenPublishesUsableAlbumDestination() async throws {
        let marker = "album.integration.begin.\(UUID().uuidString)"
        DebugLog.shared.log(marker)
        _ = try await DebugLog.shared.snapshot()
        let host = UIHostingController(rootView: ContentView())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }

        var lastTrace = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = try await DebugLog.shared.snapshot()
            lastTrace = snapshot.text.components(separatedBy: marker).last ?? ""
            let frames = try Self.measuredFrames(in: lastTrace)
            if let frame = frames.last(where: { $0.width > 0 && $0.height > 0 }) {
                XCTAssertEqual(frame.width, 46, accuracy: 0.5)
                XCTAssertEqual(frame.height, 46, accuracy: 0.5)
                XCTAssertTrue(window.bounds.contains(frame), "相册目标必须落在当前窗口内")
                return
            }
        }
        XCTFail("主拍摄界面没有给保存动效提供有效相册位置：\(lastTrace.suffix(800))")
    }

    private static func measuredFrames(in trace: String) throws -> [CGRect] {
        let expression = try NSRegularExpression(pattern: #"save\.animation\.album_measured frame=\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\)"#)
        let text = trace as NSString
        return expression.matches(in: trace, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let values = (1...4).compactMap { Double(text.substring(with: match.range(at: $0))) }
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }
}
