import AVFoundation
import CoreImage

final class RoundedPIPInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let primaryTrackID: CMPersistentTrackID
    let secondaryTrackID: CMPersistentTrackID
    let primaryTransform: CGAffineTransform
    let secondaryTransform: CGAffineTransform
    let pipFrame: CGRect

    let enablePostProcessing = true
    let containsTweening = false
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? {
        [NSNumber(value: primaryTrackID), NSNumber(value: secondaryTrackID)]
    }

    init(timeRange: CMTimeRange, primaryTrackID: CMPersistentTrackID, secondaryTrackID: CMPersistentTrackID, primaryTransform: CGAffineTransform, secondaryTransform: CGAffineTransform, pipFrame: CGRect) {
        self.timeRange = timeRange
        self.primaryTrackID = primaryTrackID
        self.secondaryTrackID = secondaryTrackID
        self.primaryTransform = primaryTransform
        self.secondaryTransform = secondaryTransform
        self.pipFrame = pipFrame
    }
}

final class RoundedPIPCompositor: NSObject, AVVideoCompositing {
    private let renderingQueue = DispatchQueue(label: "com.luolihao.dualcapture.rounded-pip")
    // Long recordings produce many intermediate Core Image objects. Disable
    // intermediate caching and scope each rendered frame in an autorelease
    // pool so exporting does not grow memory usage with recording duration.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderingQueue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderingQueue.async { [weak self] in
            autoreleasepool {
                guard let self,
                      let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? RoundedPIPInstruction,
                      let primaryBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.primaryTrackID),
                      let secondaryBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.secondaryTrackID),
                      let outputBuffer = self.renderContext?.newPixelBuffer() else {
                    asyncVideoCompositionRequest.finish(with: NSError(domain: "DualCapture", code: -1))
                    return
                }

                let renderSize = self.renderContext?.size ?? .zero
                let renderRect = CGRect(origin: .zero, size: renderSize)
                let primary = self.image(CIImage(cvPixelBuffer: primaryBuffer), transformedBy: instruction.primaryTransform, in: renderRect)
                let secondary = self.image(CIImage(cvPixelBuffer: secondaryBuffer), transformedBy: instruction.secondaryTransform, in: instruction.pipFrame)
                let cornerRadius: CGFloat = 24
                let borderWidth: CGFloat = 5
                let mask = self.roundedMask(for: instruction.pipFrame, radius: cornerRadius)
                let clippedSecondary = self.masked(secondary, by: mask)
                let border = self.roundedBorder(for: instruction.pipFrame, radius: cornerRadius, width: borderWidth)
                let output = border.composited(over: clippedSecondary.composited(over: primary)).cropped(to: renderRect)
                self.ciContext.render(output, to: outputBuffer, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: outputBuffer)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func image(_ image: CIImage, transformedBy transform: CGAffineTransform, in target: CGRect) -> CIImage {
        let transformed = image.transformed(by: transform)
        let dx = target.midX - transformed.extent.midX
        let dy = target.midY - transformed.extent.midY
        return transformed.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private func roundedMask(for frame: CGRect, radius: CGFloat) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")!
        filter.setValue(CIVector(cgRect: frame), forKey: kCIInputExtentKey)
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: kCIInputColorKey)
        return filter.outputImage!
    }

    private func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIBlendWithAlphaMask")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage!
    }

    private func roundedBorder(for frame: CGRect, radius: CGFloat, width: CGFloat) -> CIImage {
        let outer = roundedMask(for: frame, radius: radius)
        let inner = roundedMask(for: frame.insetBy(dx: width, dy: width), radius: max(0, radius - width))
        let white = CIImage(color: .white).cropped(to: frame)
        let outerWhite = masked(white, by: outer)
        let clear = CIImage(color: .clear).cropped(to: frame)
        let removeCenter = CIFilter(name: "CIBlendWithAlphaMask")!
        removeCenter.setValue(clear, forKey: kCIInputImageKey)
        removeCenter.setValue(outerWhite, forKey: kCIInputBackgroundImageKey)
        removeCenter.setValue(inner, forKey: kCIInputMaskImageKey)
        return removeCenter.outputImage!
    }
}
