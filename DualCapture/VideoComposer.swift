import AVFoundation
import UIKit

enum VideoComposer {
    static func makeComposite(front: URL, rear: URL, layout: CaptureLayout, primarySide: CameraSide) async throws -> URL {
        let frontAsset = AVURLAsset(url: front)
        let rearAsset = AVURLAsset(url: rear)
        guard let frontVideo = try await frontAsset.loadTracks(withMediaType: .video).first,
              let rearVideo = try await rearAsset.loadTracks(withMediaType: .video).first else { throw ComposerError.missingTrack }
        let composition = AVMutableComposition()
        guard let frontTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let rearTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ComposerError.missingTrack }
        let frontTimeRange = try await frontVideo.load(.timeRange)
        let rearTimeRange = try await rearVideo.load(.timeRange)
        let duration = min(frontTimeRange.duration, rearTimeRange.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let frontSourceRange = CMTimeRange(start: frontTimeRange.start, duration: duration)
        let rearSourceRange = CMTimeRange(start: rearTimeRange.start, duration: duration)
        try frontTrack.insertTimeRange(frontSourceRange, of: frontVideo, at: .zero)
        try rearTrack.insertTimeRange(rearSourceRange, of: rearVideo, at: .zero)
        if let rearAudio = try await rearAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = CMTimeRange(start: rearAudio.timeRange.start, duration: min(rearAudio.timeRange.duration, duration))
            try audioTrack.insertTimeRange(audioRange, of: rearAudio, at: .zero)
        }

        let renderSize = CGSize(width: 1080, height: 1920)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        let rearLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: rearTrack)
        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
        let primaryVideo = primarySide == .front ? frontVideo : rearVideo
        let secondaryVideo = primarySide == .front ? rearVideo : frontVideo
        let primaryLayer = primarySide == .front ? frontLayer : rearLayer
        let secondaryLayer = primarySide == .front ? rearLayer : frontLayer
        var pipFrame = CGRect.zero
        switch layout {
        case .pictureInPicture:
            primaryLayer.setTransform(transform(for: primaryVideo, in: CGRect(origin: .zero, size: renderSize), fill: true), at: .zero)
            let insetWidth = renderSize.width * PictureInPictureMetrics.widthRatio
            let insetHeight = renderSize.height * PictureInPictureMetrics.heightRatio
            pipFrame = CGRect(
                x: renderSize.width - insetWidth - renderSize.width * PictureInPictureMetrics.rightMarginRatio,
                y: renderSize.height * PictureInPictureMetrics.topMarginRatio,
                width: insetWidth,
                height: insetHeight
            )
            secondaryLayer.setTransform(transform(for: secondaryVideo, in: pipFrame, fill: true), at: .zero)
            instruction.layerInstructions = [secondaryLayer, primaryLayer]
        case .split:
            let top = CGRect(x: 0, y: 0, width: renderSize.width, height: renderSize.height / 2)
            let bottom = CGRect(x: 0, y: renderSize.height / 2, width: renderSize.width, height: renderSize.height / 2)
            primaryLayer.setTransform(transform(for: primaryVideo, in: top, fill: true), at: .zero)
            secondaryLayer.setTransform(transform(for: secondaryVideo, in: bottom, fill: true), at: .zero)
            instruction.layerInstructions = [secondaryLayer, primaryLayer]
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        if layout == .pictureInPicture {
            let parentLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = parentLayer.bounds
            let borderLayer = CAShapeLayer()
            // Draw the outline using an explicit path. This keeps the visible
            // outer edge aligned with the complete PIP rectangle instead of
            // relying on CAShapeLayer's inward border rendering.
            let borderWidth: CGFloat = 5
            let borderFrame = CGRect(
                x: pipFrame.minX,
                y: renderSize.height - pipFrame.maxY,
                width: pipFrame.width,
                height: pipFrame.height
            ).insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2)
            borderLayer.frame = borderFrame
            borderLayer.path = UIBezierPath(
                roundedRect: borderLayer.bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                cornerRadius: 24
            ).cgPath
            borderLayer.lineWidth = borderWidth
            borderLayer.strokeColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            borderLayer.fillColor = nil
            parentLayer.addSublayer(videoLayer)
            parentLayer.addSublayer(borderLayer)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }
        let destination = front.deletingLastPathComponent().appendingPathComponent("composite-\(layout.rawValue)-\(primarySide == .front ? "front" : "rear").mov")
        try? FileManager.default.removeItem(at: destination)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw ComposerError.cannotExport }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else { throw exporter.error ?? ComposerError.cannotExport }
        return destination
    }

    private static func transform(for track: AVAssetTrack, in target: CGRect, fill: Bool) -> CGAffineTransform {
        let preferred = track.preferredTransform
        let sourceRect = CGRect(origin: .zero, size: track.naturalSize)
        let orientedRect = sourceRect.applying(preferred)
        let width = abs(orientedRect.width), height = abs(orientedRect.height)
        guard width > 0, height > 0 else { return preferred }
        let scale = fill ? max(target.width / width, target.height / height) : min(target.width / width, target.height / height)
        let scaledWidth = width * scale
        let scaledHeight = height * scale
        let x = target.minX + (target.width - scaledWidth) / 2
        let y = target.minY + (target.height - scaledHeight) / 2
        // Apply the track's camera rotation first, then scale, then place the
        // resulting oriented image in the target rect. Keeping translation as
        // the outer transform avoids rotated portrait tracks shifting outside
        // the PIP bounds.
        return CGAffineTransform(translationX: x, y: y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(preferred)
    }
}

private enum ComposerError: Error { case missingTrack, cannotExport }
