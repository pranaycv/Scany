import CoreImage
import Foundation
import Vision

/// Detects a document page quadrilateral with Vision.
/// Primary path: `VNDetectDocumentSegmentationRequest`.
/// Fallback: `VNDetectRectanglesRequest` tuned for paper-like aspect ratios.
final class DocumentDetector: @unchecked Sendable {
    private let segmentationRequest: VNDetectDocumentSegmentationRequest = {
        let request = VNDetectDocumentSegmentationRequest()
        request.preferBackgroundProcessing = false
        return request
    }()

    private let rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.75
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.18
        request.quadratureTolerance = 20
        request.maximumObservations = 4
        return request
    }()

    func detect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> DocumentQuad? {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        return perform(on: handler)
    }

    func detect(
        ciImage: CIImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> DocumentQuad? {
        let handler = VNImageRequestHandler(
            ciImage: ciImage,
            orientation: orientation,
            options: [:]
        )
        return perform(on: handler)
    }

    private func perform(on handler: VNImageRequestHandler) -> DocumentQuad? {
        if let quad = runSegmentation(handler) {
            return quad
        }
        return runRectangles(handler)
    }

    private func runSegmentation(_ handler: VNImageRequestHandler) -> DocumentQuad? {
        do {
            try handler.perform([segmentationRequest])
        } catch {
            return nil
        }
        return bestQuad(from: rectangles(in: segmentationRequest.results))
    }

    private func runRectangles(_ handler: VNImageRequestHandler) -> DocumentQuad? {
        do {
            try handler.perform([rectangleRequest])
        } catch {
            return nil
        }
        return bestQuad(from: rectangles(in: rectangleRequest.results))
    }

    private func rectangles(in observations: [VNObservation]?) -> [VNRectangleObservation]? {
        observations?.compactMap { $0 as? VNRectangleObservation }
    }

    private func bestQuad(from observations: [VNRectangleObservation]?) -> DocumentQuad? {
        guard let observations, !observations.isEmpty else { return nil }
        let ranked = observations.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            return area(lhs.boundingBox) > area(rhs.boundingBox)
        }
        guard let observation = ranked.first, observation.confidence >= 0.35 else {
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
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
