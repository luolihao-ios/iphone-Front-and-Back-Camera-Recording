import XCTest
import SwiftUI
@testable import DualCapture

final class SaveAnimationPlaybackTests: XCTestCase {
    func testClockDoesNotRunBeforeViewMountsOrRestartOnLayoutChange() {
        let date = Date(timeIntervalSince1970: 1000)
        var clock = SaveAnimationClock()
        XCTAssertEqual(clock.progress(at: date.addingTimeInterval(100)), 0)
        clock.start(at: date)
        XCTAssertEqual(clock.progress(at: date), 0)
        XCTAssertEqual(clock.progress(at: date.addingTimeInterval(0.375)), 0.5, accuracy: 0.001)
        clock.start(at: date.addingTimeInterval(0.375))
        XCTAssertEqual(clock.progress(at: date.addingTimeInterval(0.75)), 1)
    }

    @MainActor
    func testMountedAnimationFinishesOnceWithoutParentProgressUpdates() async {
        let finished = expectation(description: "挂载后的动效自行推进并完成")
        finished.assertForOverFulfill = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let host = UIHostingController(rootView: GenieSaveAnimation(image: image,
            target: CGRect(x: 40, y: 650, width: 46, height: 46)) { finished.fulfill() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try? await Task.sleep(for: .milliseconds(100))
        let earlyFrame = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }.pngData()
        try? await Task.sleep(for: .milliseconds(300))
        let middleFrame = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }.pngData()
        XCTAssertNotNil(earlyFrame)
        XCTAssertNotEqual(earlyFrame, middleFrame, "不能在挂载时直接跳到终点；中间帧必须实际变化")
        await fulfillment(of: [finished], timeout: 3)
    }

    @MainActor
    func testResizingMountedAnimationCommitsThumbnailBeforeOldTargetFliesOffscreen() async {
        let finished = expectation(description: "窗口改变后立即结束旧坐标动效")
        finished.assertForOverFulfill = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let host = UIHostingController(rootView: GenieSaveAnimation(image: image,
            target: CGRect(x: 40, y: 650, width: 46, height: 46)) { finished.fulfill() })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        try? await Task.sleep(for: .milliseconds(100))
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        await fulfillment(of: [finished], timeout: 0.5)
    }
}
