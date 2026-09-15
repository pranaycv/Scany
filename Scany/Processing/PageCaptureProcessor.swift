import CoreImage
import Foundation
import UIKit

enum PageCaptureProcessor {
    enum Failure: LocalizedError {
        case flatten
        case save

        var errorDescription: String? {
            switch self {
            case .flatten:
                return "Could not flatten that page. Try again with the whole page visible."
            case .save:
                return "Could not save the captured page."
            }
        }
    }

    /// Rotate to the phone, detect a crop quad, and keep the full photo for
    /// the user to adjust before warping into document coordinates.
    static func preparePreview(
        image: CIImage,
        preferredQuad: DocumentQuad?,
        directory: URL,
        deviceRotationDegrees: CGFloat,
        jpegData: Data? = nil
    ) throws -> PendingCapture {
        let photoID = UUID()
        let photoURL = directory.appendingPathComponent("\(photoID.uuidString)-full.jpg")

        let upright: CIImage
        if abs(deviceRotationDegrees) < 1, let jpegData {
            try jpegData.write(to: photoURL, options: .atomic)
            upright = CIImage(contentsOf: photoURL, options: [.applyOrientationProperty: true])
                ?? image
        } else {
            upright = OrientationCorrector.alignedToPhone(
                image,
                rotationDegrees: deviceRotationDegrees
            )
            do {
                try ScanImageFactory.writeJPEG(upright, to: photoURL, quality: 0.97)
            } catch {
                throw Failure.save
            }
        }

        let detected = DocumentDetector().detect(ciImage: upright, quality: .still)
        // Video-frame quads are only valid when the still was not rotated.
        let liveFallback = abs(deviceRotationDegrees) < 1 ? preferredQuad : nil
        let correctedStill = detected.map { QuadCorrector.correctingOutlierCorner($0) }
        let correctedLive = liveFallback.map { QuadCorrector.correctingOutlierCorner($0) }
        let candidate = [correctedStill, correctedLive]
            .compactMap { $0 }
            .first { $0.isAcceptedPage }
        let quad = candidate?.alignedToImageUp() ?? DocumentQuad.fallbackFullFrame()

        let display = ScanImageFactory.uiImage(
            from: ScanImageFactory.downscaled(upright, maxDimension: 2000)
        ) ?? UIImage()

        return PendingCapture(photoURL: photoURL, displayImage: display, quad: quad)
    }

    static func displayImage(from photoURL: URL, maxDimension: CGFloat = 1800) -> UIImage? {
        guard let photo = ScanImageFactory.ciImage(from: photoURL) else { return nil }
        return ScanImageFactory.uiImage(
            from: ScanImageFactory.downscaled(photo, maxDimension: maxDimension)
        )
    }

    /// Keeps the original photo for preview. Perspective is applied later for PDF.
    static func commit(
        photoURL: URL,
        quad: DocumentQuad,
        directory _: URL
    ) throws -> ScannedPage {
        guard let photo = ScanImageFactory.ciImage(from: photoURL) else {
            throw Failure.save
        }

        let pageID = UUID()
        let crop = axisAlignedCrop(photo, quad: quad)
        let thumbnail = ScanImageFactory.thumbnail(from: crop) ?? UIImage()
        return ScannedPage(
            id: pageID,
            createdAt: Date(),
            originalURL: photoURL,
            cropQuad: quad,
            thumbnail: thumbnail
        )
    }

    /// Flattens the original photo into a rectangular page for PDF export.
    static func flattenedImage(
        photoURL: URL,
        quad: DocumentQuad,
        enhance: Bool,
        rotationDegrees: CGFloat = 0
    ) throws -> CIImage {
        guard let photo = ScanImageFactory.ciImage(from: photoURL) else {
            throw Failure.save
        }
        guard var corrected = PerspectiveCorrector.mapToDocumentCoordinates(
            image: photo,
            quad: quad
        ) else {
            throw Failure.flatten
        }
        // PDF pages are ~letter size. Warp at 4K then shrink before enhance so
        // save/preview stay interactive.
        corrected = ScanImageFactory.downscaled(corrected, maxDimension: 3200)
        if enhance {
            corrected = ImageEnhancer.enhance(corrected)
        }
        if rotationDegrees != 0 {
            corrected = OrientationCorrector.rotate(corrected, degrees: rotationDegrees)
        }
        return corrected
    }

    static func makeThumbnail(photoURL: URL, quad: DocumentQuad) -> UIImage? {
        guard let photo = ScanImageFactory.ciImage(from: photoURL) else { return nil }
        let crop = axisAlignedCrop(photo, quad: quad)
        return ScanImageFactory.thumbnail(from: crop)
    }

    /// Flattened page for on-screen preview and PDF. Same warp, enhance, and rotation.
    static func flattenedPreview(
        from displayImage: UIImage,
        quad: DocumentQuad,
        enhance: Bool = false,
        rotationDegrees: CGFloat = 0
    ) -> UIImage? {
        guard let ciImage = CIImage(image: displayImage) else { return nil }
        return renderFlattenedPreview(
            ciImage,
            quad: quad,
            enhance: enhance,
            rotationDegrees: rotationDegrees
        )
    }

    static func flattenedPreview(
        photoURL: URL,
        quad: DocumentQuad,
        enhance: Bool,
        rotationDegrees: CGFloat,
        maxDimension: CGFloat = 2000
    ) -> UIImage? {
        guard let photo = ScanImageFactory.ciImage(from: photoURL) else { return nil }
        let display = ScanImageFactory.downscaled(photo, maxDimension: maxDimension)
        return renderFlattenedPreview(
            display,
            quad: quad,
            enhance: enhance,
            rotationDegrees: rotationDegrees
        )
    }

    private static func renderFlattenedPreview(
        _ image: CIImage,
        quad: DocumentQuad,
        enhance: Bool,
        rotationDegrees: CGFloat
    ) -> UIImage? {
        guard var current = PerspectiveCorrector.mapToDocumentCoordinates(
            image: image,
            quad: quad
        ) else { return nil }
        if enhance {
            current = ImageEnhancer.enhance(current)
        }
        if rotationDegrees != 0 {
            current = OrientationCorrector.rotate(current, degrees: rotationDegrees)
        }
        return ScanImageFactory.uiImage(from: current)
    }

    static func axisAlignedCrop(_ image: CIImage, quad: DocumentQuad) -> CIImage {
        let extent = image.extent
        let box = quad.alignedToImageUp().withBoundingBoxFromCorners().boundingBox
        var rect = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        rect = rect.integral.intersection(extent.integral)
        guard !rect.isEmpty else { return image }
        var cropped = image.cropped(to: rect)
        if cropped.extent.origin != .zero {
            cropped = cropped.transformed(
                by: CGAffineTransform(
                    translationX: -cropped.extent.origin.x,
                    y: -cropped.extent.origin.y
                )
            )
        }
        return cropped
    }
}
