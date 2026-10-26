import Foundation

struct SaveAnimationDestination {
    private var latestFrame: CGRect?
    private(set) var activeFrame: CGRect?

    mutating func update(_ frame: CGRect) {
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return }
        latestFrame = frame
    }

    mutating func begin() -> CGRect? {
        activeFrame = latestFrame
        return activeFrame
    }

    mutating func end() { activeFrame = nil }
}

enum SaveAnimationGeometry {
    static func localTarget(_ frame: CGRect, overlayOrigin: CGPoint) -> CGRect {
        frame.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
    }

    static func frame(progress: CGFloat, in bounds: CGRect, target: CGRect) -> CGRect {
        let p = min(max(progress, 0), 1)
        let start = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.46)
        let center = CGPoint(x: start.x + (target.midX - start.x) * p,
                             y: start.y + (target.midY - start.y) * p)
        let width = bounds.width + (target.width * 0.7 - bounds.width) * p
        let height = bounds.height * 0.68 + (target.height * 0.7 - bounds.height * 0.68) * p
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    static func maskVertices(in rect: CGRect, progress: CGFloat) -> [CGPoint] {
        let p = min(max(progress, 0), 1)
        let bottomPhase = min(p / 0.55, 1)
        let topPhase = max(0, (p - 0.35) / 0.65)
        let bottomInset = rect.width * 0.48 * bottomPhase
        let topInset = rect.width * 0.48 * topPhase
        return [CGPoint(x: rect.minX + topInset, y: rect.minY),
                CGPoint(x: rect.maxX - topInset, y: rect.minY),
                CGPoint(x: rect.maxX - bottomInset, y: rect.maxY),
                CGPoint(x: rect.minX + bottomInset, y: rect.maxY)]
    }
}
