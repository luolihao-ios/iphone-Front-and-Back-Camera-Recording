import Photos

enum PhotoLibrarySaver {
    static func save(_ urls: [URL]) async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else { throw PhotoSaveError.permissionDenied }
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                urls.forEach { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: $0) }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? PhotoSaveError.saveFailed) }
            }
        }
    }
}

private enum PhotoSaveError: Error { case permissionDenied, saveFailed }
