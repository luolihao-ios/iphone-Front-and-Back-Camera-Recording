import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraManager
    let configuration: RealtimeRecordingConfiguration
    let onMoveWindow: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        camera.previewSink = { [weak view] side, sample in
            DispatchQueue.main.async { view?.display(sample, from: side) }
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.configuration = configuration
        view.canMoveWindow = !camera.isRecording && !camera.isProcessing
        view.onMoveWindow = onMoveWindow
    }
}

final class PreviewView: UIView, UIGestureRecognizerDelegate {
    private let rearLayer = AVSampleBufferDisplayLayer()
    private let frontLayer = AVSampleBufferDisplayLayer()
    private var panStartCenter = CGPoint.zero
    var configuration = RealtimeRecordingConfiguration(layout: .pictureInPicture, primarySide: .rear) {
        didSet { setNeedsLayout() }
    }
    var canMoveWindow = true
    var onMoveWindow: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rearLayer.videoGravity = .resizeAspectFill
        frontLayer.videoGravity = .resizeAspectFill
        rearLayer.masksToBounds = true
        frontLayer.masksToBounds = true
        layer.addSublayer(rearLayer)
        layer.addSublayer(frontLayer)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moveWindow(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mainLayer = displayLayer(for: configuration.primarySide)
        let secondaryLayer = displayLayer(for: configuration.secondarySide)
        let frames = RealtimeVideoLayout.frames(for: configuration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.insertSublayer(mainLayer, at: 0)
        layer.insertSublayer(secondaryLayer, above: mainLayer)
        mainLayer.frame = RealtimeVideoLayout.scaledFrame(frames.primary, configuration: configuration, in: bounds)
        mainLayer.cornerRadius = 0
        mainLayer.borderWidth = 0
        secondaryLayer.isHidden = configuration.layout == .fullScreen
        secondaryLayer.frame = RealtimeVideoLayout.secondaryFrame(for: configuration, in: bounds)
        secondaryLayer.cornerRadius = RealtimeVideoLayout.secondaryCornerRadius(for: configuration, in: bounds)
        secondaryLayer.borderWidth = 0
        CATransaction.commit()
    }

    func display(_ sample: CMSampleBuffer, from side: CameraSide) {
        let displayLayer = self.displayLayer(for: side)
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canMoveWindow, configuration.layout == .pictureInPicture else { return false }
        return displayLayer(for: configuration.secondarySide).frame.contains(gestureRecognizer.location(in: self))
    }

    @objc private func moveWindow(_ gesture: UIPanGestureRecognizer) {
        guard canMoveWindow, bounds.width > 0, bounds.height > 0 else { return }
        let secondary = displayLayer(for: configuration.secondarySide)
        if gesture.state == .began { panStartCenter = secondary.position }
        let translation = gesture.translation(in: self)
        var settings = configuration.pictureInPicture
        settings.center = CGPoint(x: (panStartCenter.x + translation.x) / bounds.width,
                                  y: (panStartCenter.y + translation.y) / bounds.height)
        let clamped = settings.frame(in: bounds.size)
        onMoveWindow?(CGPoint(x: clamped.midX / bounds.width, y: clamped.midY / bounds.height))
    }

    private func displayLayer(for side: CameraSide) -> AVSampleBufferDisplayLayer {
        side == .rear ? rearLayer : frontLayer
    }
}
