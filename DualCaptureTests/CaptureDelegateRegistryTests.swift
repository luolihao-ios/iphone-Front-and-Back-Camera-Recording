import XCTest
@testable import DualCapture

final class CaptureDelegateRegistryTests: XCTestCase {
    func testRegistryKeepsCaptureDelegateAliveAfterCallerReleasesIt() {
        let registry = CaptureDelegateRegistry()
        weak var weakDelegate: NSObject?
        autoreleasepool {
            let delegate = NSObject()
            weakDelegate = delegate
            registry.retain(delegate)
        }
        XCTAssertNotNil(weakDelegate)
        XCTAssertEqual(registry.count, 1)
    }
}
