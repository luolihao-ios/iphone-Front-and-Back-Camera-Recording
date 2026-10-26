import XCTest
import SwiftUI
@testable import DualCapture

final class AlbumTargetIntegrationTests: XCTestCase {
    @MainActor
    func testProbeWaitsForWindowThenReportsActualPositionAndResize() async {
        let first = expectation(description: "首次进入窗口后测量")
        let moved = expectation(description: "窗口内位置变化后重新测量")
        let probe = AlbumAnimationTargetView(frame: CGRect(x: 0, y: 0, width: 46, height: 46))
        let container = UIView(frame: CGRect(x: 40, y: 600, width: 46, height: 46))
        container.addSubview(probe)
        var frames: [CGRect] = []
        probe.onFrame = { frame in
            frames.append(frame)
            if frames.count == 1 { first.fulfill() }
            if frames.count == 2 { moved.fulfill() }
        }
        probe.requestMeasurement()
        await Task.yield()
        XCTAssertTrue(frames.isEmpty, "尚未加入窗口不能发布假坐标")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        window.addSubview(container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; container.removeFromSuperview() }
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(frames.first, CGRect(x: 40, y: 600, width: 46, height: 46))
        // 没有尺寸变化的位置移动也应更新目标，不能一直缓存启动时的位置。
        container.frame.origin = CGPoint(x: 70, y: 650)
        probe.requestMeasurement()
        await fulfillment(of: [moved], timeout: 1)
        XCTAssertEqual(frames.last, CGRect(x: 70, y: 650, width: 46, height: 46))
        probe.requestMeasurement()
        await Task.yield()
        XCTAssertEqual(frames.count, 2, "相同布局必须去重，避免状态更新造成循环")
    }

    @MainActor
    func testWindowCoordinatesAlignWithSwiftUIOverlayAfterSafeAreaInsets() async throws {
        for size in [CGSize(width: 414, height: 896), CGSize(width: 1024, height: 768)] {
            var overlayOrigin: CGPoint?
            var albumFrame: CGRect?
            let originReady = expectation(description: "读取带安全区的覆盖层位置")
            let albumReady = expectation(description: "读取窗口内相册位置")
            let host = UIHostingController(rootView: GeometryReader { proxy in
                Color.clear.onAppear {
                    overlayOrigin = proxy.frame(in: .global).origin
                    originReady.fulfill()
                }
            })
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 23, bottom: 34, right: 0)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            let probe = AlbumAnimationTargetView(frame: CGRect(x: 70, y: 500, width: 46, height: 46))
            probe.onFrame = { frame in
                guard albumFrame == nil else { return }
                albumFrame = frame
                albumReady.fulfill()
            }
            host.view.addSubview(probe)
            host.view.layoutIfNeeded()
            await fulfillment(of: [originReady, albumReady], timeout: 2)
            let origin = try XCTUnwrap(overlayOrigin)
            let globalFrame = try XCTUnwrap(albumFrame)
            let localFrame = SaveAnimationGeometry.localTarget(globalFrame, overlayOrigin: origin)
            let expected = probe.convert(probe.bounds, to: host.view).offsetBy(
                dx: -host.view.safeAreaInsets.left, dy: -host.view.safeAreaInsets.top)
            XCTAssertGreaterThan(origin.y, 0)
            XCTAssertEqual(localFrame.midX, expected.midX, accuracy: 0.5)
            XCTAssertEqual(localFrame.midY, expected.midY, accuracy: 0.5)
        }
    }

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
