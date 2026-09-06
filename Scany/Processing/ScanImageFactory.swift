import CoreImage
import Foundation
import ImageIO
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
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return uiImage(from: scaled)
    }

    static func ciImage(from url: URL) -> CIImage? {
        CIImage(contentsOf: url)
    }

    static func writeEnhanced(_ image: CIImage, id: UUID, directory: URL) -> URL? {
        let enhanced = ImageEnhancer.enhance(image)
        let url = directory.appendingPathComponent("\(id.uuidString)-enhanced.jpg")
        do {
            try writeJPEG(enhanced, to: url, quality: 0.9)
            return url
        } catch {
            return nil
        }
    }
}

enum ScanImageError: Error {
    case renderFailed
}
