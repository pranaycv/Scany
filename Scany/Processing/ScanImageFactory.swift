import CoreImage
import Foundation
import UIKit

/// Shared CIContext and disk helpers for captured pages.
enum ScanImageFactory {
    static let context: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }()

    static func uiImage(from image: CIImage) -> UIImage? {
        let rect = image.extent.integral
        guard !rect.isEmpty,
              let cgImage = context.createCGImage(image, from: rect)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    static func jpegData(from image: CIImage, quality: CGFloat = 0.9) -> Data? {
        let rect = image.extent.integral
        guard !rect.isEmpty else { return nil }
        return context.jpegRepresentation(
            of: image.cropped(to: rect),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }

    static func writeJPEG(_ image: CIImage, to url: URL, quality: CGFloat = 0.9) throws {
        guard let data = jpegData(from: image, quality: quality) else {
            throw ScanImageError.renderFailed
        }
        try data.write(to: url, options: .atomic)
    }

    static func thumbnail(from image: CIImage, maxDimension: CGFloat = 240) -> UIImage? {
        uiImage(from: downscaled(image, maxDimension: maxDimension))
    }

    static func downscaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if scaled.extent.origin != .zero {
            scaled = scaled.transformed(
                by: CGAffineTransform(
                    translationX: -scaled.extent.origin.x,
                    y: -scaled.extent.origin.y
                )
            )
        }
        return scaled
    }

    static func ciImage(from url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
}

enum ScanImageError: Error {
    case renderFailed
}
