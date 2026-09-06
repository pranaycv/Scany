import Foundation
import UIKit

struct ScannedPage: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let originalURL: URL
    var enhancedURL: URL?
    let thumbnail: UIImage

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ScannedPage, rhs: ScannedPage) -> Bool {
        lhs.id == rhs.id
            && lhs.originalURL == rhs.originalURL
            && lhs.enhancedURL == rhs.enhancedURL
    }

    func displayImage(enhanced: Bool) -> UIImage? {
        let url = (enhanced ? enhancedURL : nil) ?? originalURL
        return UIImage(contentsOfFile: url.path)
    }
}
