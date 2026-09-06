import Foundation
import SwiftUI
import UIKit

enum PDFExporter {
    /// Builds a multi-page PDF. Each scan becomes its own page, sized to the
    /// image aspect (capped at US Letter) so the share sheet can Save to Files.
    static func export(
        title: String,
        pageImageURLs: [URL],
        outputDirectory: URL
    ) throws -> URL {
        let images = pageImageURLs.compactMap { UIImage(contentsOfFile: $0.path) }
        guard !images.isEmpty else { throw PDFExportError.noPages }

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        let url = outputDirectory.appendingPathComponent("\(safeTitle).pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Scany",
            kCGPDFContextTitle as String: title
        ]

        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: letter, format: format)
        try renderer.writePDF(to: url) { context in
            for image in images {
                let size = pageSizeFitting(image.size)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return url
    }

    private static func pageSizeFitting(_ size: CGSize) -> CGSize {
        let maxWidth: CGFloat = 612
        let maxHeight: CGFloat = 792
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let widthScale = maxWidth / size.width
        let heightScale = maxHeight / size.height
        let scale = min(widthScale, heightScale)
        let applied = min(max(scale, 0.15), 2.0)
        return CGSize(width: size.width * applied, height: size.height * applied)
    }
}

enum PDFExportError: LocalizedError {
    case noPages
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noPages:
            return "There are no pages to export."
        case .renderFailed:
            return "Scany could not create the PDF."
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
