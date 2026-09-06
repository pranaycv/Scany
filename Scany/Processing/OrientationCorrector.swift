import CoreImage
import Foundation
import UIKit
import Vision

/// Makes a captured page upright regardless of how the paper sat on the desk.
/// Prefers live text orientation; falls back to a portrait-page heuristic.
enum OrientationCorrector {
    private static let angles: [CGFloat] = [0, 90, 180, 270]

    static func uprightImage(from image: CIImage) -> CIImage {
        let scores = angles.map { angle -> (CGFloat, Int) in
            let rotated = rotate(image, degrees: angle)
            return (angle, textScore(for: rotated))
        }

        if let best = scores.max(by: { $0.1 < $1.1 }), best.1 >= 2 {
            return rotate(image, degrees: best.0)
        }

        // No reliable text: prefer portrait (typical letter / A4).
        if image.extent.width > image.extent.height * 1.12 {
            return rotate(image, degrees: 90)
        }
        return image
    }

    static func rotate(_ image: CIImage, degrees: CGFloat) -> CIImage {
        guard degrees.truncatingRemainder(dividingBy: 360) != 0 else { return image }

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

    /// Cheap, downscaled text pass. Higher score = more / more confident glyphs.
    private static func textScore(for image: CIImage) -> Int {
        let scaled = downscale(image, maxDimension: 720)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018

        let handler = VNImageRequestHandler(ciImage: scaled, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return 0
        }

        guard let observations = request.results, !observations.isEmpty else { return 0 }

        var score = 0
        for observation in observations {
            let candidates = observation.topCandidates(1)
            guard let text = candidates.first else { continue }
            let trimmed = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let confidenceBoost = Int(text.confidence * 4)
            score += 1 + confidenceBoost + min(trimmed.count / 8, 3)
        }
        return score
    }

    private static func downscale(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
