import CoreImage
import Foundation
import UIKit
import Vision

/// Picks 0/90/180/270° from readable text, then a small deskew if lines are crooked.
enum PageDeskewer {
    static func alignmentDegrees(from image: CIImage) -> CGFloat {
        let working = ScanImageFactory.downscaled(image, maxDimension: 1100)
        guard let cgImage = ScanImageFactory.context.createCGImage(
            working,
            from: working.extent.integral
        ) else { return 0 }

        var bestScore = 0
        var bestDegrees: CGFloat = 0
        var uprightScore = 0
        for degrees in [CGFloat(0), 90, 180, 270] {
            let sample: CGImage
            if degrees == 0 {
                sample = cgImage
            } else if let rotated = rotate(cgImage, degrees: degrees) {
                sample = rotated
            } else {
                continue
            }
            let score = textScore(sample)
            if degrees == 0 { uprightScore = score }
            if score > bestScore {
                bestScore = score
                bestDegrees = degrees
            }
        }

        if bestScore < 6 || (bestDegrees != 0 && bestScore < uprightScore + 4) {
            bestDegrees = 0
        }

        let aligned = bestDegrees == 0
            ? working
            : OrientationCorrector.rotate(working, degrees: bestDegrees)
        let fine = fineDeskewDegrees(from: aligned)
        return ScannedPage.normalized(bestDegrees + fine)
    }

    private static func textScore(_ image: CGImage) -> Int {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let text = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined() ?? ""
        return text.filter { !$0.isWhitespace && !$0.isNewline }.count
    }

    private static func fineDeskewDegrees(from image: CIImage) -> CGFloat {
        guard let gray = renderGray(image) else { return 0 }
        var bestDegrees: CGFloat = 0
        var bestScore = horizontalLineScore(gray)
        let baseline = bestScore
        for fine in stride(from: CGFloat(-6), through: 6, by: 1) where fine != 0 {
            guard let rotated = rotatedGray(gray, degrees: fine) else { continue }
            let score = horizontalLineScore(rotated)
            if score > bestScore {
                bestScore = score
                bestDegrees = fine
            }
        }
        guard bestScore > baseline * 1.12 else { return 0 }
        return bestDegrees
    }

    private static func rotate(_ image: CGImage, degrees: CGFloat) -> CGImage? {
        let radians = degrees * .pi / 180
        let original = CGSize(width: image.width, height: image.height)
        let rotatedRect = CGRect(origin: .zero, size: original)
            .applying(CGAffineTransform(rotationAngle: radians))
        let size = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))
        let renderer = UIGraphicsImageRenderer(size: size)
        let output = renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: radians)
            ctx.cgContext.translateBy(x: -original.width / 2, y: -original.height / 2)
            ctx.cgContext.draw(image, in: CGRect(origin: .zero, size: original))
        }
        return output.cgImage
    }

    private struct GrayBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static func renderGray(_ image: CIImage) -> GrayBuffer? {
        let working = ScanImageFactory.downscaled(image, maxDimension: 360)
        let rect = working.extent.integral
        guard rect.width > 8, rect.height > 8,
              let cgImage = ScanImageFactory.context.createCGImage(working, from: rect)
        else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = (width + 15) & ~15
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let ok = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        if bytesPerRow == width {
            return GrayBuffer(width: width, height: height, bytes: bytes)
        }
        var packed = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let src = y * bytesPerRow
            let dst = y * width
            packed.replaceSubrange(dst..<(dst + width), with: bytes[src..<(src + width)])
        }
        return GrayBuffer(width: width, height: height, bytes: packed)
    }

    private static func rotatedGray(_ source: GrayBuffer, degrees: CGFloat) -> GrayBuffer? {
        if degrees == 0 { return source }
        guard let provider = CGDataProvider(data: Data(source.bytes) as CFData),
              let cgImage = CGImage(
                width: source.width,
                height: source.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: source.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let rotated = rotate(cgImage, degrees: degrees)
        else { return nil }

        let width = rotated.width
        let height = rotated.height
        var bytes = [UInt8](repeating: 255, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(rotated, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return GrayBuffer(width: width, height: height, bytes: bytes)
    }

    private static func horizontalLineScore(_ buffer: GrayBuffer) -> Double {
        let width = buffer.width
        let height = buffer.height
        guard width > 8, height > 8 else { return 0 }
        var rowSums = [Double](repeating: 0, count: height)
        buffer.bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<height {
                var sum = 0
                let row = base + y * width
                for x in 0..<width {
                    let value = Int(row[x])
                    if value < 170 { sum += 255 - value }
                }
                rowSums[y] = Double(sum)
            }
        }
        let mean = rowSums.reduce(0, +) / Double(height)
        var variance = 0.0
        for value in rowSums {
            let delta = value - mean
            variance += delta * delta
        }
        return variance / Double(height * max(width, 1))
    }
}
