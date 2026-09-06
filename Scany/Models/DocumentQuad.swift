import CoreGraphics
import Foundation

/// Four corners of a detected page, in Vision's normalized image space
/// (origin at the bottom-left, values in 0...1).
struct DocumentQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var confidence: Float
    var boundingBox: CGRect

    var corners: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// Fraction of the frame covered by the axis-aligned bounding box.
    var fillRatio: CGFloat {
        max(0, boundingBox.width) * max(0, boundingBox.height)
    }

    /// Mean Euclidean distance between corresponding corners, in normalized units.
    func jitter(to other: DocumentQuad) -> CGFloat {
        let pairs = zip(corners, other.corners)
        let total = pairs.reduce(CGFloat.zero) { sum, pair in
            sum + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }
        return total / 4
    }

    /// Physical edge lengths in normalized space, used to size the unwarped page.
    var destinationSize: CGSize {
        let top = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let bottom = hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)
        let left = hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
        let right = hypot(topRight.x - bottomRight.x, topRight.y - bottomRight.y)
        let width = max((top + bottom) / 2, 0.05)
        let height = max((left + right) / 2, 0.05)
        return CGSize(width: width, height: height)
    }
}
