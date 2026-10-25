import CoreImage

/// 照片与实时录像共用同一套裁切、位置和遮罩。
enum FrameCompositor {
    static func composite(primary: CIImage, secondary: CIImage?, configuration: RealtimeRecordingConfiguration) -> CIImage? {
        let frames = RealtimeVideoLayout.frames(for: configuration)
        let canvas = CGRect(origin: .zero, size: configuration.renderSize)
        func ciFrame(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let background = CIImage(color: .black).cropped(to: canvas)
        let main = aspectFill(primary, into: ciFrame(frames.primary)).composited(over: background)
        guard configuration.layout != .fullScreen else { return main.cropped(to: canvas) }
        guard let secondary else { return nil }
        let frame = ciFrame(frames.secondary)
        let overlay = aspectFill(secondary, into: frame)
        guard frames.secondaryCornerRadius > 0 else {
            return overlay.composited(over: main).cropped(to: canvas)
        }
        guard let generator = CIFilter(name: "CIRoundedRectangleGenerator"),
              let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        generator.setValue(CIVector(cgRect: frame), forKey: kCIInputExtentKey)
        generator.setValue(frames.secondaryCornerRadius, forKey: kCIInputRadiusKey)
        generator.setValue(CIColor.white, forKey: kCIInputColorKey)
        guard let mask = generator.outputImage else { return nil }
        let fullMask = mask.composited(over: CIImage(color: .black).cropped(to: canvas))
        blend.setValue(overlay, forKey: kCIInputImageKey)
        blend.setValue(main, forKey: kCIInputBackgroundImageKey)
        blend.setValue(fullMask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: canvas)
    }

    private static func aspectFill(_ image: CIImage, into destination: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: destination.midX - scaled.extent.midX,
            y: destination.midY - scaled.extent.midY)).cropped(to: destination)
    }
}
