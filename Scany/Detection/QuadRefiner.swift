import CoreGraphics
import CoreImage
import Foundation

struct LumaMap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func value(x: Int, y: Int) -> Float {
        let sx = min(max(x, 0), width - 1)
        let sy = min(max(y, 0), height - 1)
        return Float(pixels[sy * width + sx])
    }

    func bilinear(_ point: CGPoint) -> Float {
        let x = min(max(point.x, 0), CGFloat(width - 1))
        let y = min(max(point.y, 0), CGFloat(height - 1))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = Float(x - CGFloat(x0))
        let fy = Float(y - CGFloat(y0))
        let v00 = value(x: x0, y: y0)
        let v10 = value(x: x1, y: y0)
        let v01 = value(x: x0, y: y1)
        let v11 = value(x: x1, y: y1)
        return v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + v01 * (1 - fx) * fy + v11 * fx * fy
    }

    func visionToPixel(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(max(width - 1, 1)),
            y: (1 - point.y) * CGFloat(max(height - 1, 1))
        )
    }

    func pixelToVision(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x / CGFloat(max(width - 1, 1)),
            y: 1 - point.y / CGFloat(max(height - 1, 1))
        )
    }

    static func make(from image: CIImage, maxDimension: CGFloat) -> LumaMap? {
        let longest = max(image.extent.width, image.extent.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        var scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if scaled.extent.origin != .zero {
            scaled = scaled.transformed(
                by: CGAffineTransform(
                    translationX: -scaled.extent.origin.x,
                    y: -scaled.extent.origin.y
                )
            )
        }
        let rect = scaled.extent.integral
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard width > 16, height > 16 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        ScanImageFactory.context.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: width,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        return LumaMap(width: width, height: height, pixels: pixels)
    }
}

/// Snaps a coarse Vision quad onto the actual paper edges using local gradients.
enum QuadRefiner {
    static func snapToEdges(
        _ quad: DocumentQuad,
        luma: LumaMap,
        searchFraction: CGFloat,
        samplesPerEdge: Int
    ) -> DocumentQuad {
        let pixelQuad = quad.corners.map { luma.visionToPixel($0) }
        guard pixelQuad.count == 4 else { return quad }

        let centroid = CGPoint(
            x: pixelQuad.map(\.x).reduce(0, +) / 4,
            y: pixelQuad.map(\.y).reduce(0, +) / 4
        )
        let radius = max(6, searchFraction * CGFloat(min(luma.width, luma.height)))

        var lines: [Line] = []
        lines.reserveCapacity(4)
        for index in 0..<4 {
            let start = pixelQuad[index]
            let end = pixelQuad[(index + 1) % 4]
            if let line = fitEdge(
                from: start,
                to: end,
                centroid: centroid,
                luma: luma,
                radius: radius,
                samples: samplesPerEdge
            ) {
                lines.append(line)
            } else {
                lines.append(Line(through: start, and: end))
            }
        }

        var refinedPixels: [CGPoint] = []
        for index in 0..<4 {
            let previous = lines[(index + 3) % 4]
            let current = lines[index]
            if let hit = previous.intersection(with: current),
               hit.x > -8, hit.y > -8,
               hit.x < CGFloat(luma.width) + 8,
               hit.y < CGFloat(luma.height) + 8
            {
                refinedPixels.append(hit)
            } else {
                refinedPixels.append(pixelQuad[index])
            }
        }

        let refined = DocumentQuad(
            topLeft: luma.pixelToVision(refinedPixels[0]),
            topRight: luma.pixelToVision(refinedPixels[1]),
            bottomRight: luma.pixelToVision(refinedPixels[2]),
            bottomLeft: luma.pixelToVision(refinedPixels[3]),
            confidence: quad.confidence,
            boundingBox: .zero
        )
        .alignedToImageUp()
        .withBoundingBoxFromCorners()

        guard isPlausible(refined, original: quad) else { return quad }
        return refined
    }

    /// Largest convex quadrilateral on a contour — tighter than x±y extrema.
    static func quad(fromContour points: [CGPoint], confidence: Float) -> DocumentQuad? {
        let unique = densify(points)
        guard unique.count >= 4 else { return nil }
        let hull = convexHull(unique)
        guard let vertices = maximumAreaQuad(on: hull) else { return nil }
        let labeled = labelCorners(vertices)
        let xs = labeled.map(\.x)
        let ys = labeled.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let fill = box.width * box.height
        guard fill >= 0.12, fill <= 0.96 else { return nil }
        return DocumentQuad(
            topLeft: labeled[0],
            topRight: labeled[1],
            bottomRight: labeled[2],
            bottomLeft: labeled[3],
            confidence: confidence,
            boundingBox: box
        )
    }

    // MARK: - Edge fit

    private struct Line {
        var origin: CGPoint
        var direction: CGPoint

        init(origin: CGPoint, direction: CGPoint) {
            let length = hypot(direction.x, direction.y)
            self.origin = origin
            self.direction = length > 0.0001
                ? CGPoint(x: direction.x / length, y: direction.y / length)
                : CGPoint(x: 1, y: 0)
        }

        init(through a: CGPoint, and b: CGPoint) {
            self.init(origin: a, direction: CGPoint(x: b.x - a.x, y: b.y - a.y))
        }

        func intersection(with other: Line) -> CGPoint? {
            let d = direction.x * other.direction.y - direction.y * other.direction.x
            guard abs(d) > 0.0008 else { return nil }
            let t = ((other.origin.x - origin.x) * other.direction.y
                - (other.origin.y - origin.y) * other.direction.x) / d
            return CGPoint(x: origin.x + t * direction.x, y: origin.y + t * direction.y)
        }
    }

    private static func fitEdge(
        from start: CGPoint,
        to end: CGPoint,
        centroid: CGPoint,
        luma: LumaMap,
        radius: CGFloat,
        samples: Int
    ) -> Line? {
        let edge = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let length = hypot(edge.x, edge.y)
        guard length > 8 else { return nil }
        let tx = edge.x / length
        let ty = edge.y / length
        var nx = ty
        var ny = -tx
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        if (mid.x - centroid.x) * nx + (mid.y - centroid.y) * ny < 0 {
            nx = -nx
            ny = -ny
        }

        var hits: [CGPoint] = []
        hits.reserveCapacity(samples)
        let count = max(samples, 6)
        for i in 0..<count {
            let t = 0.14 + 0.72 * CGFloat(i) / CGFloat(count - 1)
            let sample = CGPoint(x: start.x + edge.x * t, y: start.y + edge.y * t)
            if let snapped = snapSample(
                sample,
                nx: nx,
                ny: ny,
                luma: luma,
                radius: radius
            ) {
                hits.append(snapped)
            }
        }
        guard hits.count >= 4 else { return nil }
        return leastSquaresLine(hits)
    }

    private static func snapSample(
        _ sample: CGPoint,
        nx: CGFloat,
        ny: CGFloat,
        luma: LumaMap,
        radius: CGFloat
    ) -> CGPoint? {
        let steps = max(Int(radius * 2), 8)
        var bestScore: Float = 0
        var bestT: CGFloat = 0
        let sigma = max(radius * 0.42, 2)
        for step in -steps...steps {
            let t = CGFloat(step) * radius / CGFloat(steps)
            let point = CGPoint(x: sample.x + nx * t, y: sample.y + ny * t)
            let inward = luma.bilinear(CGPoint(x: point.x - nx * 1.5, y: point.y - ny * 1.5))
            let outward = luma.bilinear(CGPoint(x: point.x + nx * 1.5, y: point.y + ny * 1.5))
            // Paper is usually lighter than the desk. Prefer that light→dark step
            // so we lock onto the sheet edge instead of printed text.
            let drop = inward - outward
            let gradient = max(drop, 0) * 1.7 + abs(drop) * 0.35
            let weight = Float(exp(-0.5 * pow(t / sigma, 2)))
            let score = gradient * weight
            if score > bestScore {
                bestScore = score
                bestT = t
            }
        }
        guard bestScore > 8 else { return nil }
        return CGPoint(x: sample.x + nx * bestT, y: sample.y + ny * bestT)
    }

    private static func leastSquaresLine(_ points: [CGPoint]) -> Line? {
        let n = CGFloat(points.count)
        let mx = points.map(\.x).reduce(0, +) / n
        let my = points.map(\.y).reduce(0, +) / n
        var xx: CGFloat = 0
        var yy: CGFloat = 0
        var xy: CGFloat = 0
        for point in points {
            let dx = point.x - mx
            let dy = point.y - my
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        guard xx + yy > 1 else { return nil }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        return Line(
            origin: CGPoint(x: mx, y: my),
            direction: CGPoint(x: cos(angle), y: sin(angle))
        )
    }

    private static func isPlausible(_ refined: DocumentQuad, original: DocumentQuad) -> Bool {
        guard refined.isConvex else { return false }
        let refinedCorners = refined.corners
        let originalCorners = original.corners
        var jumped = 0
        for index in 0..<4 {
            let a = refinedCorners[index]
            let b = originalCorners[index]
            if hypot(a.x - b.x, a.y - b.y) > 0.05 {
                jumped += 1
            }
        }
        // One snapped corner may fly off; QuadCorrector rebuilds it from the
        // other three. Two or more jumps means the snap is not usable.
        return jumped <= 1
    }

    // MARK: - Contour geometry

    private static func densify(_ points: [CGPoint]) -> [CGPoint] {
        var unique: [CGPoint] = []
        unique.reserveCapacity(points.count)
        for point in points {
            if let last = unique.last, hypot(last.x - point.x, last.y - point.y) < 0.002 {
                continue
            }
            unique.append(point)
        }
        return unique
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { lhs, rhs in
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0
            {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0
            {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func maximumAreaQuad(on hull: [CGPoint]) -> [CGPoint]? {
        let n = hull.count
        guard n >= 4 else { return nil }
        if n == 4 { return hull }

        var simplified = hull
        var epsilon: CGFloat = 0.008
        while simplified.count > 12, epsilon < 0.08 {
            let closed = simplified + [simplified[0]]
            let reduced = ramerDouglasPeucker(closed, epsilon: epsilon)
            simplified = reduced.count > 1 ? Array(reduced.dropLast()) : reduced
            epsilon *= 1.4
        }
        let ring = simplified.count >= 4 ? simplified : hull
        let count = ring.count
        guard count >= 4 else { return nil }
        if count == 4 { return ring }

        var best: [CGPoint] = []
        var bestArea: CGFloat = 0
        for i in 0..<(count - 3) {
            for j in (i + 1)..<(count - 2) {
                for k in (j + 1)..<(count - 1) {
                    for l in (k + 1)..<count {
                        let quad = [ring[i], ring[j], ring[k], ring[l]]
                        let area = quadArea(quad)
                        if area > bestArea {
                            bestArea = area
                            best = quad
                        }
                    }
                }
            }
        }
        return best.count == 4 ? best : nil
    }

    private static func ramerDouglasPeucker(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let distance = perpendicularDistance(points[i], first, last)
            if distance > maxDistance {
                maxDistance = distance
                index = i
            }
        }
        if maxDistance > epsilon {
            let left = ramerDouglasPeucker(Array(points[0...index]), epsilon: epsilon)
            let right = ramerDouglasPeucker(Array(points[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }

    private static func perpendicularDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return hypot(point.x - a.x, point.y - a.y) }
        return abs((point.y - a.y) * dx - (point.x - a.x) * dy) / length
    }

    private static func quadArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count == 4 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = points[i]
            let b = points[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) * 0.5
    }

    private static func labelCorners(_ points: [CGPoint]) -> [CGPoint] {
        var topLeft = points[0]
        var topRight = points[0]
        var bottomRight = points[0]
        var bottomLeft = points[0]
        for point in points {
            if point.x - point.y < topLeft.x - topLeft.y { topLeft = point }
            if point.x + point.y > topRight.x + topRight.y { topRight = point }
            if point.x - point.y > bottomRight.x - bottomRight.y { bottomRight = point }
            if point.x + point.y < bottomLeft.x + bottomLeft.y { bottomLeft = point }
        }
        return [topLeft, topRight, bottomRight, bottomLeft]
    }
}
