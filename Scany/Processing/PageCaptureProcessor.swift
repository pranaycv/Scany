import CoreImage
import Foundation
import UIKit

enum PageCaptureProcessor {
    enum Failure: LocalizedError {
        case flatten
        case save

        var errorDescription: String? {
            switch self {
            case .flatten:
                return "Could not flatten that page. Try again with the whole page visible."
            case .save:
                return "Could not save the captured page."
            }
        }
    }

    static func process(
        image: CIImage,
        preferredQuad: DocumentQuad?,
        autoEnhance: Bool,
        directory: URL
    ) throws -> ScannedPage {
        let detected = preferredQuad ?? DocumentDetector().detect(ciImage: image)
        guard let pageQuad = detected,
              var corrected = PerspectiveCorrector.correct(image: image, quad: pageQuad)
        else {
            throw Failure.flatten
        }

        corrected = OrientationCorrector.uprightImage(from: corrected)

        let pageID = UUID()
        let originalURL = directory.appendingPathComponent("\(pageID.uuidString).jpg")
        do {
            try ScanImageFactory.writeJPEG(corrected, to: originalURL, quality: 0.9)
        } catch {
            throw Failure.save
        }

        let thumbnail = ScanImageFactory.thumbnail(from: corrected) ?? UIImage()
        var page = ScannedPage(
            id: pageID,
            createdAt: Date(),
            originalURL: originalURL,
            enhancedURL: nil,
            thumbnail: thumbnail
        )

        if autoEnhance, let enhanced = ScanImageFactory.writeEnhanced(corrected, id: pageID, directory: directory) {
            page.enhancedURL = enhanced
        }
        return page
    }
}
