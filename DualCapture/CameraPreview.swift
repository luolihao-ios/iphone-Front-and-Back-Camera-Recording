import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraManager
    let layout: CaptureLayout

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        camera.previewSink = { [weak view] side, sample in
            DispatchQueue.main.async { view?.display(sample, from: side) }
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.layout = layout
    }
}

final class PreviewView: UIView {
    private let rearLayer = AVSampleBufferDisplayLayer()
    private let frontLayer = AVSampleBufferDisplayLayer()
    var layout: CaptureLayout = .pictureInPicture { didSet { setNeedsLayout() } }

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
        switch layout {
        case .pictureInPicture:
            rearLayer.frame = bounds
            let size = CGSize(width: bounds.width * 0.34, height: bounds.height * 0.25)
            frontLayer.frame = CGRect(x: bounds.maxX - size.width - 18, y: bounds.minY + 58, width: size.width, height: size.height)
        case .split:
            let width = bounds.width / 2
            rearLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            frontLayer.frame = CGRect(x: width, y: 0, width: width, height: bounds.height)
        }
    }

    func display(_ sample: CMSampleBuffer, from side: CameraSide) {
        let displayLayer = side == .rear ? rearLayer : frontLayer
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }
}
