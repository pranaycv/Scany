import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

enum PerspectiveCorrector {
    /// Maps the crop quad onto a rectangular document coordinate system.
    /// Uses a 4-point perspective warp (homography). A 3-point affine cannot
    /// flatten camera perspective; this is the transform that matches the page.
    static func mapToDocumentCoordinates(image: CIImage, quad: DocumentQuad) -> CIImage? {
        // Use the stored corner labels. Re-sorting by Y would change "up" after
        // a recrop and look like the page rotated on its own.
        correct(image: image, quad: quad)
    }

    /// Warps the detected page onto a rectangle. Corners should already be
    /// ordered so top-left/top-right match the top of the phone's camera image.
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
        filter.crop = true

        guard var output = filter.outputImage else { return nil }

        // Crop to the filter's produced extent and drop empty borders.
        let cropped = output.cropped(to: output.extent.integral)
        if cropped.extent.isEmpty { return nil }

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
