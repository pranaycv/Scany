import CoreGraphics
import Foundation

/// Auto-capture fires when the live quad has enough corner confidence and the
/// four points form a rectangle (limited skew, no runaway vertex).
struct QuadStabilizer {
    /// Vision / segmentation confidence the current quad must meet.
    var minimumConfidence: Float = 0.6
    /// Consecutive good detections before the yellow overlay is drawn.
    var overlayFrames: Int = 5
    /// Consecutive good detections before auto-capture fires.
    /// Yellow is shown from `overlayFrames` through this value, so capture
    /// happens after 20 frames with the yellow box on screen (5 + 20 = 25).
    var captureFrames: Int = 25

    private var goodStreak = 0
    private var latestQuad: DocumentQuad?

    mutating func reset() {
        goodStreak = 0
        latestQuad = nil
    }

    mutating func push(quad: DocumentQuad?) {
        guard let quad, quad.isAcceptedPage else {
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
        case detecting
        case settling
        case ready
    }

    func evaluate() -> Readiness {
        guard latestQuad != nil else { return .noPage }
        if goodStreak < overlayFrames { return .detecting }
        if goodStreak < captureFrames { return .settling }
        return .ready
    }
}
