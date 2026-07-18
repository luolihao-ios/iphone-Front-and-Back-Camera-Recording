import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraManager
    let layout: CaptureLayout
    let primarySide: CameraSide
    let onTapSide: (CameraSide) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        camera.previewSink = { [weak view] side, sample in
            DispatchQueue.main.async { view?.display(sample, from: side) }
        }
        view.onTapSide = onTapSide
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.layout = layout
        view.primarySide = primarySide
        view.onTapSide = onTapSide
    }
}

final class PreviewView: UIView {
    private let rearLayer = AVSampleBufferDisplayLayer()
    private let frontLayer = AVSampleBufferDisplayLayer()
    var layout: CaptureLayout = .pictureInPicture { didSet { setNeedsLayout() } }
    var primarySide: CameraSide = .rear { didSet { setNeedsLayout() } }
    var onTapSide: ((CameraSide) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rearLayer.videoGravity = .resizeAspectFill
        frontLayer.videoGravity = .resizeAspectFill
        frontLayer.borderColor = UIColor.white.cgColor
        frontLayer.borderWidth = 2
        layer.addSublayer(rearLayer)
        layer.addSublayer(frontLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mainLayer = layer(for: primarySide)
        let secondaryLayer = layer(for: primarySide.secondary)
        layer.insertSublayer(mainLayer, at: 0)
        layer.insertSublayer(secondaryLayer, above: mainLayer)
        switch layout {
        case .pictureInPicture:
            mainLayer.frame = bounds
            let size = CGSize(width: bounds.width * 0.34, height: bounds.height * 0.25)
            secondaryLayer.frame = CGRect(x: bounds.maxX - size.width - 18, y: bounds.minY + 58, width: size.width, height: size.height)
        case .split:
            let height = bounds.height / 2
            mainLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            secondaryLayer.frame = CGRect(x: 0, y: height, width: bounds.width, height: height)
        }
    }

    func display(_ sample: CMSampleBuffer, from side: CameraSide) {
        let displayLayer = layer(for: side)
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self) else { return }
        let composition = CaptureComposition(layout: layout, primarySide: primarySide)
        for side in composition.tapHitTestOrder where layer(for: side).frame.contains(location) {
            onTapSide?(side)
            return
        }
    }

    private func layer(for side: CameraSide) -> AVSampleBufferDisplayLayer {
        side == .rear ? rearLayer : frontLayer
    }
}
