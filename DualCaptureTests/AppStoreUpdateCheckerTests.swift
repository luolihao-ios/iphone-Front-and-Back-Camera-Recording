import XCTest
@testable import DualCapture

final class AppStoreUpdateCheckerTests: XCTestCase {
    func testReportsUpdateWhenStoreVersionIsNewerThanInstalledVersion() {
        XCTAssertTrue(AppStoreUpdateChecker.isStoreVersion("1.0.12", newerThan: "1.0.11"))
    }

    func testDoesNotReportUpdateWhenVersionsMatchOrStoreVersionIsOlder() {
        XCTAssertFalse(AppStoreUpdateChecker.isStoreVersion("1.0.11", newerThan: "1.0.11"))
        XCTAssertFalse(AppStoreUpdateChecker.isStoreVersion("1.0.10", newerThan: "1.0.11"))
    }

    func testComparesVersionsWithDifferentComponentCounts() {
        XCTAssertTrue(AppStoreUpdateChecker.isStoreVersion("1.1", newerThan: "1.0.99"))
        XCTAssertFalse(AppStoreUpdateChecker.isStoreVersion("1.0", newerThan: "1.0.0"))
    }
}
