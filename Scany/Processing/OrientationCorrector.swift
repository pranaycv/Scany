import CoreImage
import Foundation
import UIKit

/// Rotates a flattened page so "up" matches how the phone was held.
/// Text-based 90/180 guesses are intentionally not used — they invert pages.
enum OrientationCorrector {
    static func alignedToPhone(_ image: CIImage, rotationDegrees: CGFloat) -> CIImage {
        rotate(image, degrees: normalized(rotationDegrees))
    }

    static func rotate(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let degrees = normalized(degrees)
        guard degrees != 0 else { return image }

        let radians = degrees * .pi / 180
        let extent = image.extent
        let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: radians)
            .translatedBy(x: -extent.midX, y: -extent.midY)

        var rotated = image.transformed(by: transform)
        if rotated.extent.origin != .zero {
            rotated = rotated.transformed(
                by: CGAffineTransform(
                    translationX: -rotated.extent.origin.x,
                    y: -rotated.extent.origin.y
                )
            )
        }
        return rotated.cropped(to: rotated.extent.integral)
    }

    private static func normalized(_ degrees: CGFloat) -> CGFloat {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if value < 1 || value > 359 { return 0 }
        return value
    }
}
