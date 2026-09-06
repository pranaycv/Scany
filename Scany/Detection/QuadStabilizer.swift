import CoreGraphics
import CoreVideo
import Foundation

/// Tracks recent document quads and reports when the page has been held still
/// long enough, fills enough of the frame, and is sharp enough to auto-capture.
struct QuadStabilizer {
    struct Sample {
        let date: Date
        let quad: DocumentQuad
        let sharpness: Double
        let luminance: Double
    }

    /// Time the quad must stay still before we fire.
    var requiredStableDuration: TimeInterval = 0.7
    /// Average corner movement (normalized) allowed inside the window.
    var maxJitter: CGFloat = 0.016
    /// Minimum bounding-box coverage of the frame.
    var minimumFillRatio: CGFloat = 0.16
    var minimumConfidence: Float = 0.45
    /// Laplacian-variance floor; below this the frame is treated as blurry.
    var minimumSharpness: Double = 18
    /// Mean luma (0...1) below which we surface a low-light tip.
    var lowLightLuminance: Double = 0.18

    private var samples: [Sample] = []
    private let maxAge: TimeInterval = 1.2

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func push(
        quad: DocumentQuad?,
        sharpness: Double,
        luminance: Double,
        now: Date = Date()
    ) {
        samples.removeAll { now.timeIntervalSince($0.date) > maxAge }
        guard let quad else { return }
        samples.append(Sample(date: now, quad: quad, sharpness: sharpness, luminance: luminance))
    }

    var latest: Sample? { samples.last }

    var isLowLight: Bool {
        guard let latest else { return false }
        return latest.luminance < lowLightLuminance
    }

    enum Readiness: Equatable {
        case noPage
        case tooSmall
        case blurry
        case settling
        case ready
    }

    func evaluate(now: Date = Date()) -> Readiness {
        guard let latest else { return .noPage }

        if latest.quad.fillRatio < minimumFillRatio {
            return .tooSmall
        }
        if latest.quad.confidence < minimumConfidence {
            return .settling
        }
        if latest.sharpness < minimumSharpness {
            return .blurry
        }

        let window = samples.filter { now.timeIntervalSince($0.date) <= requiredStableDuration + 0.15 }
        guard let first = window.first else { return .settling }
        let span = now.timeIntervalSince(first.date)
        guard span >= requiredStableDuration else { return .settling }

        let recent = window.filter { now.timeIntervalSince($0.date) <= requiredStableDuration }
        guard recent.count >= 4 else { return .settling }

        let jitters = zip(recent.dropFirst(), recent).map { $0.0.quad.jitter(to: $0.1.quad) }
        let meanJitter = jitters.reduce(0, +) / CGFloat(max(jitters.count, 1))
        if meanJitter > maxJitter {
            return .settling
        }

        // Also require the first and last quads in the window to be close.
        if latest.quad.jitter(to: first.quad) > maxJitter * 1.6 {
            return .settling
        }

        return .ready
    }
}

enum FrameQuality {
    /// Variance of a 3x3 Laplacian on a downscaled luma image. Higher = sharper.
    static func laplacianVariance(pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Sample a coarse grid; 48x64 is enough to tell blur from sharp.
        let cols = 64
        let rows = 48
        var luma = [Double](repeating: 0, count: cols * rows)

        for row in 0..<rows {
            let sy = Int(Double(row) / Double(rows) * Double(height - 1))
            for col in 0..<cols {
                let sx = Int(Double(col) / Double(cols) * Double(width - 1))
                luma[row * cols + col] = sampleLuma(
                    base: base,
                    x: sx,
                    y: sy,
                    width: width,
                    bytesPerRow: bytesPerRow,
                    format: format
                )
            }
        }

        var values: [Double] = []
        values.reserveCapacity((cols - 2) * (rows - 2))
        for y in 1..<(rows - 1) {
            for x in 1..<(cols - 1) {
                let c = luma[y * cols + x]
                let lap =
                    luma[(y - 1) * cols + x]
                    + luma[(y + 1) * cols + x]
                    + luma[y * cols + (x - 1)]
                    + luma[y * cols + (x + 1)]
                    - 4 * c
                values.append(lap)
            }
        }

        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }

    static func meanLuminance(pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.5 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var total = 0.0
        let steps = 24
        var count = 0
        for row in 0..<steps {
            let y = Int(Double(row) / Double(steps) * Double(height - 1))
            for col in 0..<steps {
                let x = Int(Double(col) / Double(steps) * Double(width - 1))
                total += sampleLuma(
                    base: base,
                    x: x,
                    y: y,
                    width: width,
                    bytesPerRow: bytesPerRow,
                    format: format
                )
                count += 1
            }
        }
        return count == 0 ? 0.5 : total / Double(count)
    }

    private static func sampleLuma(
        base: UnsafeMutableRawPointer,
        x: Int,
        y: Int,
        width: Int,
        bytesPerRow: Int,
        format: OSType
    ) -> Double {
        // 420f / 420v store luma in the first plane.
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        {
            let row = base.advanced(by: y * bytesPerRow)
            return Double(row.load(fromByteOffset: x, as: UInt8.self)) / 255.0
        }

        // BGRA
        let row = base.advanced(by: y * bytesPerRow)
        let offset = x * 4
        let b = Double(row.load(fromByteOffset: offset, as: UInt8.self))
        let g = Double(row.load(fromByteOffset: offset + 1, as: UInt8.self))
        let r = Double(row.load(fromByteOffset: offset + 2, as: UInt8.self))
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    }
}
