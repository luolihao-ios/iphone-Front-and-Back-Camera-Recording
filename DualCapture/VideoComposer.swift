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
        let duration = min(try await frontAsset.load(.duration), try await rearAsset.load(.duration))
        let range = CMTimeRange(start: .zero, duration: duration)
        try frontTrack.insertTimeRange(range, of: frontVideo, at: .zero)
        try rearTrack.insertTimeRange(range, of: rearVideo, at: .zero)
        if let rearAudio = try await rearAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(range, of: rearAudio, at: .zero)
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
        switch layout {
        case .pictureInPicture:
            primaryLayer.setTransform(transform(for: primaryVideo, in: CGRect(origin: .zero, size: renderSize), fill: true), at: .zero)
            let inset = CGRect(x: 54, y: 110, width: 360, height: 480)
            secondaryLayer.setTransform(transform(for: secondaryVideo, in: inset, fill: true), at: .zero)
            instruction.layerInstructions = [secondaryLayer, primaryLayer]
        case .split:
            let left = CGRect(x: 0, y: 0, width: renderSize.width / 2, height: renderSize.height)
            let right = CGRect(x: renderSize.width / 2, y: 0, width: renderSize.width / 2, height: renderSize.height)
            primaryLayer.setTransform(transform(for: primaryVideo, in: left, fill: true), at: .zero)
            secondaryLayer.setTransform(transform(for: secondaryVideo, in: right, fill: true), at: .zero)
            instruction.layerInstructions = [secondaryLayer, primaryLayer]
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
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
        let source = track.naturalSize.applying(preferred)
        let width = abs(source.width), height = abs(source.height)
        guard width > 0, height > 0 else { return preferred }
        let scale = fill ? max(target.width / width, target.height / height) : min(target.width / width, target.height / height)
        let scaledWidth = width * scale, scaledHeight = height * scale
        let x = target.minX + (target.width - scaledWidth) / 2
        let y = target.minY + (target.height - scaledHeight) / 2
        return preferred.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: x, y: y))
    }
}

private enum ComposerError: Error { case missingTrack, cannotExport }
