import SwiftUI
import UIKit

/// 在相册按钮实际进入窗口并完成布局后报告位置，不经过 PreferenceKey 默认值归并。
struct AlbumAnimationTargetProbe: UIViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeUIView(context: Context) -> AlbumAnimationTargetView {
        let view = AlbumAnimationTargetView()
        view.onFrame = onFrame
        return view
    }

    func updateUIView(_ view: AlbumAnimationTargetView, context: Context) {
        view.onFrame = onFrame
        view.requestMeasurement()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AlbumAnimationTargetView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

final class AlbumAnimationTargetView: UIView {
    var onFrame: ((CGRect) -> Void)?
    private var scheduled = false
    private var lastFrame: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        lastFrame = nil
        requestMeasurement()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        requestMeasurement()
    }

    func requestMeasurement() {
        guard !scheduled else { return }
        scheduled = true
        // 等当前布局完成后再发布，避免在 UIViewRepresentable 更新中直接修改 SwiftUI 状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let window = self.window else { return }
            let frame = self.convert(self.bounds, to: window)
            guard !frame.isNull, !frame.isInfinite,
                  frame.width > 0, frame.height > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame != self.lastFrame else { return }
            self.lastFrame = frame
            self.onFrame?(frame)
        }
    }
}
