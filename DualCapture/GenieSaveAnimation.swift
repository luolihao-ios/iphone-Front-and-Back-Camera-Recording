import SwiftUI
import UIKit

/// 从视图挂载时开始计时，不能由插入视图前的状态更新直接跳到终点。
struct SaveAnimationClock {
    static let duration: TimeInterval = 0.75
    private(set) var startedAt: Date?

    mutating func start(at date: Date) {
        guard startedAt == nil else { return }
        startedAt = date
    }

    func progress(at date: Date) -> CGFloat {
        guard let startedAt else { return 0 }
        let linear = min(max(date.timeIntervalSince(startedAt) / Self.duration, 0), 1)
        return CGFloat(linear * linear * (3 - 2 * linear))
    }
}

struct GenieSaveAnimation: View {
    let image: UIImage
    let target: CGRect
    let onComplete: () -> Void
    @State private var clock = SaveAnimationClock()
    @State private var reportedMiddleFrame = false
    @State private var completed = false

    var body: some View {
        GeometryReader { proxy in
            // target 来自按钮的真实窗口坐标，覆盖层也必须使用同一全局坐标系。
            let origin = proxy.frame(in: .global).origin
            let localTarget = SaveAnimationGeometry.localTarget(target, overlayOrigin: origin)
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                let progress = clock.progress(at: context.date)
                let frame = SaveAnimationGeometry.frame(progress: progress,
                    in: CGRect(origin: .zero, size: proxy.size), target: localTarget)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(GenieShape(progress: progress))
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(1 - max(0, progress - 0.9) / 0.1)
                    .onChange(of: progress >= 0.5) { _, reachedMiddle in
                        if reachedMiddle, !reportedMiddleFrame {
                            reportedMiddleFrame = true
                            DebugLog.shared.log("save.animation.middle frame=\(frame) target=\(localTarget)")
                        }
                    }
            }
            .onAppear {
                clock.start(at: Date())
                DebugLog.shared.log("save.animation.mounted bounds=\(proxy.size) target=\(localTarget) progress=0")
            }
            .onChange(of: proxy.size) { _, _ in finish(reason: "geometry_size_changed") }
            .onChange(of: origin) { _, _ in finish(reason: "geometry_origin_changed") }
            .task {
                // 计时起点属于已挂载的动效视图，而不是等待保存的父任务。
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                finish(reason: "duration_elapsed")
            }
            .onDisappear { finish(reason: "view_disappeared") }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func finish(reason: String) {
        guard !completed else { return }
        completed = true
        DebugLog.shared.log("save.animation.completed reason=\(reason) middleFrame=\(reportedMiddleFrame)")
        onComplete()
    }
}

private struct GenieShape: Shape {
    var progress: CGFloat

    func path(in rect: CGRect) -> Path {
        let vertices = SaveAnimationGeometry.maskVertices(in: rect, progress: progress)
        var path = Path()
        path.move(to: vertices[0])
        for point in vertices.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}
