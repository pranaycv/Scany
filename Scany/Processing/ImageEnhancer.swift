import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum ImageEnhancer {
    /// Document-style cleanup: shadow lift, contrast, slight desaturation, sharpen.
    /// Applied to every page when the user enables "Auto-enhance all pages".
    static func enhance(_ image: CIImage) -> CIImage {
        var current = image

        let document = CIFilter.documentEnhancer()
        document.inputImage = current
        document.amount = 1.6
        if let output = document.outputImage {
            current = output
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = current
        controls.contrast = 1.12
        controls.saturation = 0.88
        controls.brightness = 0.015
        if let output = controls.outputImage {
            current = output
        }

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = current
        sharpen.radius = 1.1
        sharpen.intensity = 0.28
        if let output = sharpen.outputImage {
            current = output
        }

        return current.cropped(to: current.extent.integral)
    }
}
