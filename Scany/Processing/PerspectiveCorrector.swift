import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

enum PerspectiveCorrector {
    /// Warps the detected page onto a rectangle. Output is upright relative to
    /// Vision's top/bottom labels — further text-based rotation is applied later.
    static func correct(image: CIImage, quad: DocumentQuad) -> CIImage? {
        let extent = image.extent
        guard extent.width > 2, extent.height > 2 else { return nil }

        let topLeft = point(quad.topLeft, in: extent)
        let topRight = point(quad.topRight, in: extent)
        let bottomLeft = point(quad.bottomLeft, in: extent)
        let bottomRight = point(quad.bottomRight, in: extent)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight

        guard var output = filter.outputImage else { return nil }

        // Crop to the filter's produced extent and drop empty borders.
        let cropped = output.cropped(to: output.extent.integral)
        if cropped.extent.isEmpty { return nil }

        // Normalize origin to (0, 0) so later transforms stay simple.
        if cropped.extent.origin != .zero {
            output = cropped.transformed(
                by: CGAffineTransform(
                    translationX: -cropped.extent.origin.x,
                    y: -cropped.extent.origin.y
                )
            )
        } else {
            output = cropped
        }
        return output
    }

    private static func point(_ normalized: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.origin.x + normalized.x * extent.width,
            y: extent.origin.y + normalized.y * extent.height
        )
    }
}
