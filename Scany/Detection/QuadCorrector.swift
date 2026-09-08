import CoreGraphics
import Foundation

/// Rebuilds a page quad so it matches a rectangle in document space.
/// Opposite edges are parallel on the page; the image may show perspective.
/// Only the one inconsistent corner is moved, and only to the location implied
/// by the other three.
enum QuadCorrector {
    static func correctingOutlierCorner(_ quad: DocumentQuad) -> DocumentQuad {
        let pts = quad.corners
        guard pts.count == 4 else { return quad }

        let originalScore = rectangleScore(pts)
        if originalScore >= 0.82, quad.isPageRectangle {
            return quad
        }

        var bestIndex: Int?
        var bestPoint: CGPoint?
        var bestScore = originalScore
        var secondScore: CGFloat = 0

        for index in 0..<4 {
            guard let predicted = predictedCorner(at: index, of: pts) else { continue }
            let displacement = hypot(predicted.x - pts[index].x, predicted.y - pts[index].y)
            guard displacement >= 0.035 else { continue }

            var candidate = pts
            candidate[index] = predicted
            let score = rectangleScore(candidate)
            guard score > originalScore + 0.06, score >= 0.55 else { continue }

            if score > bestScore {
                secondScore = bestScore
                bestScore = score
                bestIndex = index
                bestPoint = predicted
            } else if score > secondScore {
                secondScore = score
            }
        }

        guard let bestIndex, let bestPoint, bestScore >= secondScore + 0.05 else {
            return quad
        }
        return quad.replacingCorner(at: bestIndex, with: bestPoint)
    }

    /// P4 from P1, P2, P3: complete the parallelogram in the image, then slide
    /// along the diagonal so opposite edges stay parallel on the page while
    /// allowing camera perspective.
    private static func predictedCorner(at index: Int, of pts: [CGPoint]) -> CGPoint? {
        let next = pts[(index + 1) % 4]
        let opposite = pts[(index + 2) % 4]
        let previous = pts[(index + 3) % 4]
        let parallelogram = CGPoint(
            x: next.x + previous.x - opposite.x,
            y: next.y + previous.y - opposite.y
        )
        guard parallelogram.x > -0.08, parallelogram.y > -0.08,
              parallelogram.x < 1.08, parallelogram.y < 1.08
        else { return nil }

        let diag = CGPoint(x: parallelogram.x - opposite.x, y: parallelogram.y - opposite.y)
        let diagLength = hypot(diag.x, diag.y)
        guard diagLength > 0.04 else { return parallelogram }
        let perp = CGPoint(x: -diag.y / diagLength, y: diag.x / diagLength)

        var best = parallelogram
        var bestScore: CGFloat = -1
        for dt in stride(from: CGFloat(-0.22), through: 0.22, by: 0.04) {
            for ds in stride(from: CGFloat(-0.06), through: 0.06, by: 0.03) {
                let point = CGPoint(
                    x: parallelogram.x + diag.x * dt + perp.x * ds * diagLength,
                    y: parallelogram.y + diag.y * dt + perp.y * ds * diagLength
                )
                var candidate = pts
                candidate[index] = point
                let score = rectangleScore(candidate)
                if score > bestScore {
                    bestScore = score
                    best = point
                }
            }
        }
        return best
    }

    /// Higher is a more plausible perspective rectangle. Zero if unusable.
    private static func rectangleScore(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count == 4, isConvex(pts) else { return 0 }

        var lengths: [CGFloat] = []
        var dirs: [CGPoint] = []
        lengths.reserveCapacity(4)
        dirs.reserveCapacity(4)
        for index in 0..<4 {
            let a = pts[index]
            let b = pts[(index + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0.045 else { return 0 }
            lengths.append(length)
            dirs.append(CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length))
        }
        guard let minEdge = lengths.min(), let maxEdge = lengths.max(),
              maxEdge / minEdge < 4.8
        else { return 0 }

        func sideRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            max(a, b) / max(min(a, b), 0.0001)
        }
        let oppositeRatio = max(sideRatio(lengths[0], lengths[2]), sideRatio(lengths[1], lengths[3]))
        guard oppositeRatio < 1.75 else { return 0 }

        var anglePenalty: CGFloat = 0
        for index in 0..<4 {
            let angle = abs(interiorAngle(at: pts[index], from: pts[(index + 3) % 4], to: pts[(index + 1) % 4]))
            let deviation = abs(angle - .pi / 2)
            if deviation > 40 * .pi / 180 { return 0 }
            anglePenalty += deviation
        }

        // Opposite boundary directions should be anti-parallel when those
        // page edges are parallel. Perspective lowers |dot| but keeps it high.
        let pair0 = abs(dirs[0].x * dirs[2].x + dirs[0].y * dirs[2].y)
        let pair1 = abs(dirs[1].x * dirs[3].x + dirs[1].y * dirs[3].y)
        guard pair0 > 0.42, pair1 > 0.42 else { return 0 }

        let aspect = max(lengths[0] + lengths[2], 0.001) / max(lengths[1] + lengths[3], 0.001)
        let aspectPenalty = min(abs(log(aspect)) / log(3.2), 1)

        let camera = cameraRectangleConsistency(pts)
        let angleScore = max(0, 1 - anglePenalty / (36 * .pi / 180 * 4))
        let ratioScore = max(0, 1 - (oppositeRatio - 1) / 0.75)
        let parallelScore = (pair0 + pair1) / 2

        return 0.28 * angleScore
            + 0.22 * ratioScore
            + 0.22 * parallelScore
            + 0.18 * camera
            + 0.10 * (1 - aspectPenalty)
    }

    /// Vanishing points of opposite edges should match a pinhole view of a
    /// rectangle (orthogonal directions on the page).
    private static func cameraRectangleConsistency(_ pts: [CGPoint]) -> CGFloat {
        let vpH = intersection(pts[0], pts[1], pts[3], pts[2])
        let vpV = intersection(pts[1], pts[2], pts[0], pts[3])
        let center = CGPoint(x: 0.5, y: 0.5)

        if vpH == nil && vpV == nil {
            // Both pairs parallel in the image: affine view of a parallelogram.
            return 0.85
        }
        guard let vpH, let vpV else {
            // One-point perspective trapezoid.
            return 0.72
        }

        let d1 = CGPoint(x: vpH.x - center.x, y: vpH.y - center.y)
        let d2 = CGPoint(x: vpV.x - center.x, y: vpV.y - center.y)
        let f2 = -(d1.x * d2.x + d1.y * d2.y)
        if f2 <= 0.08 { return 0.15 }
        if f2 > 14 { return 0.45 }
        return 0.95
    }

    private static func isConvex(_ pts: [CGPoint]) -> Bool {
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

    private static func interiorAngle(at vertex: CGPoint, from previous: CGPoint, to next: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: previous.x - vertex.x, y: previous.y - vertex.y)
        let v2 = CGPoint(x: next.x - vertex.x, y: next.y - vertex.y)
        return atan2(v1.x * v2.y - v1.y * v2.x, v1.x * v2.x + v1.y * v2.y)
    }

    private static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let d1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let d2 = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let denom = d1.x * d2.y - d1.y * d2.x
        guard abs(denom) > 1e-6 else { return nil }
        let t = ((c.x - a.x) * d2.y - (c.y - a.y) * d2.x) / denom
        return CGPoint(x: a.x + t * d1.x, y: a.y + t * d1.y)
    }
}

extension DocumentQuad {
    func replacingCorner(at index: Int, with point: CGPoint) -> DocumentQuad {
        var pts = corners
        guard pts.indices.contains(index) else { return self }
        pts[index] = point
        return DocumentQuad(
            topLeft: pts[0],
            topRight: pts[1],
            bottomRight: pts[2],
            bottomLeft: pts[3],
            confidence: confidence,
            boundingBox: .zero
        )
        .withBoundingBoxFromCorners()
    }
}
