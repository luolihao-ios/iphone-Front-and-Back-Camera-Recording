import XCTest
@testable import DualCapture

final class SaveAnimationGeometryTests: XCTestCase {
    func testHiddenAlbumButtonDoesNotResetLastKnownDestinationToScreenOrigin() {
        var destination = SaveAnimationDestination()
        destination.update(CGRect(x: 40, y: 650, width: 46, height: 46))
        destination.update(.zero)
        XCTAssertEqual(destination.begin(), CGRect(x: 40, y: 650, width: 46, height: 46))
    }

    func testTargetDoesNotChangeHalfwayThroughAnimationWhenLayoutUpdates() {
        var destination = SaveAnimationDestination()
        destination.update(CGRect(x: 40, y: 650, width: 46, height: 46))
        _ = destination.begin()
        destination.update(CGRect(x: 50, y: 660, width: 46, height: 46))
        XCTAssertEqual(destination.activeFrame, CGRect(x: 40, y: 650, width: 46, height: 46))
        destination.end()
        XCTAssertEqual(destination.begin(), CGRect(x: 50, y: 660, width: 46, height: 46))
    }

    func testMissingDestinationSkipsAnimationRatherThanFlyingToZero() {
        var destination = SaveAnimationDestination()
        destination.update(.zero)
        destination.update(.null)
        destination.update(CGRect(x: CGFloat.nan, y: 10, width: 46, height: 46))
        XCTAssertNil(destination.begin())
    }

    func testTrajectoryMovesDownAndLeftIntoMeasuredAlbumCenter() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 760)
        let target = CGRect(x: 40, y: 650, width: 46, height: 46)
        var previous = SaveAnimationGeometry.frame(progress: 0, in: bounds, target: target)
        for index in 1...20 {
            let next = SaveAnimationGeometry.frame(progress: CGFloat(index) / 20, in: bounds, target: target)
            XCTAssertLessThanOrEqual(next.midX, previous.midX)
            XCTAssertGreaterThanOrEqual(next.midY, previous.midY)
            previous = next
        }
        XCTAssertEqual(previous.midX, 63, accuracy: 0.001)
        XCTAssertEqual(previous.midY, 673, accuracy: 0.001)
        XCTAssertTrue(target.contains(previous))
    }

    func testTargetConversionAccountsForAnimationOverlayOrigin() {
        let local = SaveAnimationGeometry.localTarget(CGRect(x: 40, y: 650, width: 46, height: 46),
            overlayOrigin: CGPoint(x: 0, y: 59))
        XCTAssertEqual(local, CGRect(x: 40, y: 591, width: 46, height: 46))
    }

    func testFunnelNeverCrossesOrTurnsUpsideDownAtEnd() {
        for index in 0...100 {
            let vertices = SaveAnimationGeometry.maskVertices(in: CGRect(x: 0, y: 0, width: 200, height: 400),
                progress: CGFloat(index) / 100)
            XCTAssertEqual(vertices.count, 4)
            XCTAssertLessThan(vertices[0].y, vertices[3].y)
            XCTAssertLessThan(vertices[1].y, vertices[2].y)
            XCTAssertLessThan(vertices[0].x, vertices[1].x)
            XCTAssertLessThan(vertices[3].x, vertices[2].x)
            XCTAssertGreaterThanOrEqual(vertices[3].x, vertices[0].x)
        }
    }
}
