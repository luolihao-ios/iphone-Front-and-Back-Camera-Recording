import AVFoundation

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
            let frames = VideoLayoutFrames.splitFrames(in: renderSize)
            // A composition layer cannot clip aspect-fill video to its half.
            // Fit each stream inside its own equal frame so neither can spill
            // into the other half of the saved video.
            primaryLayer.setTransform(transform(for: primaryVideo, in: frames.top, fill: false), at: .zero)
            secondaryLayer.setTransform(transform(for: secondaryVideo, in: frames.bottom, fill: false), at: .zero)
            instruction.layerInstructions = [secondaryLayer, primaryLayer]
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        // Use AVFoundation's native compositor for every layout. The custom
        // per-frame rounded PIP compositor consumed too much memory for longer
        // recordings and could leave the app unresponsive while saving.
        videoComposition.instructions = [instruction]
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
        let scaledWidth = width * scale, scaledHeight = height * scale
        let x = target.minX + (target.width - scaledWidth) / 2
        let y = target.minY + (target.height - scaledHeight) / 2
        // Keep the track transform first; this is the order that preserves the
        // camera's portrait orientation and places the PIP on the right side.
        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}

private enum ComposerError: Error { case missingTrack, cannotExport }
