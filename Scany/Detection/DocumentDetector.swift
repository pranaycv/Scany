import CoreImage
import Foundation
import Vision

/// Detects a document page quadrilateral with Vision, then snaps corners to
/// paper edges.
///
/// 1. `VNDetectDocumentSegmentationRequest` finds the page region (often a mask).
/// 2. Contours on that mask produce a tight 4-vertex hull — not x±y extrema.
/// 3. `VNDetectRectanglesRequest` is the fallback if segmentation finds nothing.
/// 4. `QuadRefiner` walks each edge and locks it onto the strongest gradient.
final class DocumentDetector: @unchecked Sendable {
    enum Quality {
        case live
        case still
    }

    private let segmentationRequest: VNDetectDocumentSegmentationRequest = {
        let request = VNDetectDocumentSegmentationRequest()
        request.preferBackgroundProcessing = false
        return request
    }()

    private let rectangleRequest: VNDetectRectanglesRequest = {
        makeRectangleRequest(minimumConfidence: 0.7)
    }()

    private let contoursRequest: VNDetectContoursRequest = {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 768
        request.contrastAdjustment = 2.0
        return request
    }()

    func detect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        quality: Quality = .live
    ) -> DocumentQuad? {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        return perform(on: handler, source: source, quality: quality)
    }

    func detect(
        ciImage: CIImage,
        orientation: CGImagePropertyOrientation = .up,
        quality: Quality = .still
    ) -> DocumentQuad? {
        let image = orientation == .up ? ciImage : ciImage.oriented(orientation)
        let handler = VNImageRequestHandler(
            ciImage: image,
            orientation: .up,
            options: [:]
        )
        return perform(on: handler, source: image, quality: quality)
    }

    private func perform(
        on handler: VNImageRequestHandler,
        source: CIImage,
        quality: Quality
    ) -> DocumentQuad? {
        let coarse = runSegmentation(handler) ?? runRectangles(handler)
        guard let coarse else { return nil }

        let maxDimension: CGFloat = quality == .live ? 400 : 720
        let search: CGFloat = quality == .live ? 0.032 : 0.048
        let samples = quality == .live ? 9 : 16
        let aligned = coarse.alignedToImageUp()
        let refined: DocumentQuad
        if let luma = LumaMap.make(from: source, maxDimension: maxDimension) {
            refined = QuadRefiner.snapToEdges(
                aligned,
                luma: luma,
                searchFraction: search,
                samplesPerEdge: samples
            )
        } else {
            refined = aligned
        }
        let corrected = QuadCorrector.correctingOutlierCorner(refined)
        guard corrected.isPageRectangle else { return nil }
        return corrected
    }

    private func runSegmentation(_ handler: VNImageRequestHandler) -> DocumentQuad? {
        do {
            try handler.perform([segmentationRequest])
        } catch {
            return nil
        }

        let results = segmentationRequest.results ?? []
        if let mask = results.compactMap({ $0 as? VNPixelBufferObservation }).first,
           let maskQuad = quadFromMask(mask.pixelBuffer, confidence: mask.confidence)
        {
            return maskQuad
        }
        return bestQuad(from: rectangles(in: results))
    }

    private func runRectangles(_ handler: VNImageRequestHandler) -> DocumentQuad? {
        do {
            try handler.perform([rectangleRequest])
        } catch {
            return nil
        }
        return bestQuad(from: rectangles(in: rectangleRequest.results))
    }

    private func quadFromMask(_ pixelBuffer: CVPixelBuffer, confidence: Float) -> DocumentQuad? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([contoursRequest])
        } catch {
            return nil
        }
        guard let observation = contoursRequest.results?.first else { return nil }

        let contour = observation.topLevelContours.max(by: { lhs, rhs in
            lhs.pointCount < rhs.pointCount
        })
        guard let contour, contour.pointCount >= 4 else { return nil }

        var points: [CGPoint] = []
        contour.normalizedPath.applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(pts[0])
            case .addQuadCurveToPoint:
                points.append(pts[1])
            case .addCurveToPoint:
                points.append(pts[2])
            default:
                break
            }
        }
        let reported = confidence > 0.01 ? confidence : 0.85
        return QuadRefiner.quad(fromContour: points, confidence: reported)
    }

    private func rectangles(in observations: [VNObservation]?) -> [VNRectangleObservation]? {
        observations?.compactMap { $0 as? VNRectangleObservation }
    }

    private func bestQuad(from observations: [VNRectangleObservation]?) -> DocumentQuad? {
        guard let observations, !observations.isEmpty else { return nil }

        let ranked = observations.sorted { lhs, rhs in
            paperScore(lhs) > paperScore(rhs)
        }
        guard let observation = ranked.first, paperScore(observation) > 0.18 else {
            return nil
        }
        return DocumentQuad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomRight: observation.bottomRight,
            bottomLeft: observation.bottomLeft,
            confidence: observation.confidence,
            boundingBox: observation.boundingBox
        )
        .alignedToImageUp()
        .withBoundingBoxFromCorners()
    }

    /// Prefer page-like aspect and coverage; reject near-full-frame desk quads.
    private func paperScore(_ observation: VNRectangleObservation) -> CGFloat {
        let fill = observation.boundingBox.width * observation.boundingBox.height
        guard observation.confidence >= 0.55, fill >= 0.12, fill <= 0.94 else {
            return 0
        }
        let aspect = min(observation.boundingBox.width, observation.boundingBox.height)
            / max(observation.boundingBox.width, observation.boundingBox.height)
        let aspectScore = 1 - min(abs(aspect - 0.72), 0.45) / 0.45
        let fillScore: CGFloat
        if fill < 0.2 {
            fillScore = fill / 0.2
        } else if fill > 0.86 {
            fillScore = max(0, 1 - (fill - 0.86) / 0.14)
        } else {
            fillScore = 1
        }
        return CGFloat(observation.confidence) * 0.4 + aspectScore * 0.28 + fillScore * 0.32
    }

    private static func makeRectangleRequest(minimumConfidence: Float) -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = minimumConfidence
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.18
        request.quadratureTolerance = 8
        request.maximumObservations = 6
        return request
    }
}
