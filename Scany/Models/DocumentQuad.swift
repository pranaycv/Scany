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
    /// When true, overlay and auto-capture use a looser page gate (FastViT heatmaps).
    var lenientGeometry: Bool = false

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

    /// True when this looks like the same sheet still sitting in the viewfinder.
    func isLikelySamePage(as other: DocumentQuad) -> Bool {
        jitter(to: other) < 0.16 && abs(fillRatio - other.fillRatio) < 0.14
    }

    /// Vision path: four corners must look like a page rectangle.
    var isPageRectangle: Bool { passesPageGeometry(Self.strictPageLimits) }

    /// Overlay / auto-capture gate. Same strict rectangle as Vision.
    var isAcceptedPage: Bool { isPageRectangle }

    /// True when the four corners form a page rectangle: opposite edges stay
    /// parallel on the page, with enough slack for camera perspective. One
    /// runaway corner fails until QuadCorrector rebuilds it from the other three.
    private func passesPageGeometry(_ limits: PageLimits) -> Bool {
        guard isConvex else { return false }

        let pts = corners
        var lengths: [CGFloat] = []
        lengths.reserveCapacity(4)
        for index in 0..<4 {
            let a = pts[index]
            let b = pts[(index + 1) % 4]
            lengths.append(hypot(b.x - a.x, b.y - a.y))
        }
        guard let minEdge = lengths.min(), let maxEdge = lengths.max(),
              minEdge > limits.minEdge, maxEdge / minEdge < limits.maxEdgeRatio
        else { return false }

        func sideRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            max(a, b) / max(min(a, b), 0.0001)
        }
        guard sideRatio(lengths[0], lengths[2]) < limits.oppositeSideRatio,
              sideRatio(lengths[1], lengths[3]) < limits.oppositeSideRatio
        else { return false }

        var dirs: [CGPoint] = []
        dirs.reserveCapacity(4)
        for index in 0..<4 {
            let a = pts[index]
            let b = pts[(index + 1) % 4]
            let length = lengths[index]
            dirs.append(CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length))
        }
        let oppositeAlign0 = abs(dirs[0].x * dirs[2].x + dirs[0].y * dirs[2].y)
        let oppositeAlign1 = abs(dirs[1].x * dirs[3].x + dirs[1].y * dirs[3].y)
        guard oppositeAlign0 > limits.oppositeAlign, oppositeAlign1 > limits.oppositeAlign else {
            return false
        }

        for index in 0..<4 {
            let previous = pts[(index + 3) % 4]
            let point = pts[index]
            let next = pts[(index + 1) % 4]
            let angle = abs(interiorAngle(at: point, from: previous, to: next))
            if abs(angle - .pi / 2) > limits.maxSkew {
                return false
            }
        }

        let center = CGPoint(
            x: pts.map(\.x).reduce(0, +) / 4,
            y: pts.map(\.y).reduce(0, +) / 4
        )
        let radii = pts.map { hypot($0.x - center.x, $0.y - center.y) }
        let sortedRadii = radii.sorted()
        let medianRadius = (sortedRadii[1] + sortedRadii[2]) / 2
        guard medianRadius > limits.minMedianRadius else { return false }
        if radii.contains(where: {
            $0 > medianRadius * limits.radiusHigh || $0 < medianRadius * limits.radiusLow
        }) {
            return false
        }

        let sortedLengths = lengths.sorted()
        let typicalEdge = (sortedLengths[1] + sortedLengths[2]) / 2
        let quadScale = max(typicalEdge, medianRadius * 2)
        for index in 0..<4 {
            let others = pts.enumerated().compactMap { $0.offset == index ? nil : $0.element }
            let xs = others.map(\.x)
            let ys = others.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max()
            else { return false }
            let point = pts[index]
            let dx = max(minX - point.x, 0, point.x - maxX)
            let dy = max(minY - point.y, 0, point.y - maxY)
            if hypot(dx, dy) > quadScale * limits.outlierFraction {
                return false
            }
        }
        return true
    }

    private struct PageLimits {
        var minEdge: CGFloat
        var maxEdgeRatio: CGFloat
        var oppositeSideRatio: CGFloat
        var oppositeAlign: CGFloat
        var maxSkew: CGFloat
        var minMedianRadius: CGFloat
        var radiusHigh: CGFloat
        var radiusLow: CGFloat
        var outlierFraction: CGFloat
    }

    private static let strictPageLimits = PageLimits(
        minEdge: 0.045,
        maxEdgeRatio: 4.8,
        oppositeSideRatio: 1.65,
        oppositeAlign: 0.45,
        maxSkew: 36 * .pi / 180,
        minMedianRadius: 0.04,
        radiusHigh: 1.50,
        radiusLow: 0.58,
        outlierFraction: 0.14
    )

    var isConvex: Bool {
        let pts = corners
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = pts[index]
            let b = pts[(index + 1) % 4]
            let c = pts[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-7 { continue }
            if sign == 0 {
                sign = cross
            } else if sign * cross < 0 {
                return false
            }
        }
        return true
    }

    private func interiorAngle(at vertex: CGPoint, from previous: CGPoint, to next: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: previous.x - vertex.x, y: previous.y - vertex.y)
        let v2 = CGPoint(x: next.x - vertex.x, y: next.y - vertex.y)
        return atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y)
    }

    /// Reorders corners so "top" is toward the top of the camera image (the
    /// phone's notch / top edge), not Vision's guess or the printed text.
    func alignedToImageUp() -> DocumentQuad {
        let sortedByY = corners.sorted { $0.y > $1.y }
        guard sortedByY.count == 4 else { return self }
        let top = Array(sortedByY.prefix(2)).sorted { $0.x < $1.x }
        let bottom = Array(sortedByY.suffix(2)).sorted { $0.x < $1.x }
        return DocumentQuad(
            topLeft: top[0],
            topRight: top[1],
            bottomRight: bottom[1],
            bottomLeft: bottom[0],
            confidence: confidence,
            boundingBox: boundingBox,
            lenientGeometry: lenientGeometry
        )
    }

    static func fallbackFullFrame(inset: CGFloat = 0.08) -> DocumentQuad {
        let minV = inset
        let maxV = 1 - inset
        return DocumentQuad(
            topLeft: CGPoint(x: minV, y: maxV),
            topRight: CGPoint(x: maxV, y: maxV),
            bottomRight: CGPoint(x: maxV, y: minV),
            bottomLeft: CGPoint(x: minV, y: minV),
            confidence: 0.2,
            boundingBox: CGRect(x: minV, y: minV, width: maxV - minV, height: maxV - minV)
        )
    }

    /// Training / DocCorner space: normalized 0...1, origin at the image
    /// top-left. Vision uses a bottom-left origin, so y is flipped (`1 - y`).
    func trainingQuadNorm() -> [String: [Double]] {
        func pair(_ point: CGPoint) -> [Double] {
            [
                Self.trainingCoordinate(point.x),
                Self.trainingCoordinate(1 - point.y)
            ]
        }
        return [
            "tl": pair(topLeft),
            "tr": pair(topRight),
            "br": pair(bottomRight),
            "bl": pair(bottomLeft)
        ]
    }

    private static func trainingCoordinate(_ value: CGFloat) -> Double {
        let clamped = min(max(Double(value), 0), 1)
        return (clamped * 1_000_000).rounded() / 1_000_000
    }

    func withBoundingBoxFromCorners() -> DocumentQuad {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return self }
        var copy = self
        copy.boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return copy
    }

    func contracted(by fraction: CGFloat) -> DocumentQuad {
        let amount = min(max(fraction, 0), 0.2)
        guard amount > 0 else { return self }
        let cx = (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4
        let cy = (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4
        func pull(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x + (cx - point.x) * amount,
                y: point.y + (cy - point.y) * amount
            )
        }
        return DocumentQuad(
            topLeft: pull(topLeft),
            topRight: pull(topRight),
            bottomRight: pull(bottomRight),
            bottomLeft: pull(bottomLeft),
            confidence: confidence,
            boundingBox: boundingBox.insetBy(
                dx: boundingBox.width * amount * 0.5,
                dy: boundingBox.height * amount * 0.5
            ),
            lenientGeometry: lenientGeometry
        )
    }
}
