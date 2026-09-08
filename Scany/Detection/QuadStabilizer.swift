import CoreGraphics
import Foundation

/// Auto-capture fires when the live quad has enough corner confidence and the
/// four points form a rectangle (limited skew, no runaway vertex).
struct QuadStabilizer {
    /// Vision / segmentation confidence the current quad must meet.
    var minimumConfidence: Float = 0.6
    /// Consecutive good detections before we fire. Two frames is enough to
    /// ignore a single noisy hit without waiting on blur, fill, or jitter.
    var requiredGoodFrames: Int = 15

    private var goodStreak = 0
    private var latestQuad: DocumentQuad?

    mutating func reset() {
        goodStreak = 0
        latestQuad = nil
    }

    mutating func push(quad: DocumentQuad?) {
        guard let quad, quad.isPageRectangle else {
            goodStreak = 0
            latestQuad = nil
            return
        }
        latestQuad = quad
        if quad.confidence >= minimumConfidence {
            goodStreak += 1
        } else {
            goodStreak = 0
        }
    }

    enum Readiness: Equatable {
        case noPage
        case settling
        case ready
    }

    func evaluate() -> Readiness {
        guard latestQuad != nil else { return .noPage }
        guard goodStreak >= requiredGoodFrames else { return .settling }
        return .ready
    }
}
