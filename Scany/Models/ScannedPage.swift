import Foundation
import UIKit

struct ScannedPage: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    /// Full captured photo, still in camera perspective.
    let originalURL: URL
    /// Crop corners in the original photo. Used to flatten the page for PDF.
    var cropQuad: DocumentQuad
    var thumbnail: UIImage
    /// `nil` follows a caller-supplied default. Pages stamp this on capture.
    var enhanceOverride: Bool?
    /// True after the user taps Rotate. Preview and PDF then use `manualRotationDegrees`.
    var userLockedOrientation: Bool
    /// 90° steps from the Rotate button. 0, 90, 180, or 270.
    var manualRotationDegrees: CGFloat
    /// Deskew angle from line alignment. Not used for display while the user controls rotate.
    var cachedAutoRotation: CGFloat?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        originalURL: URL,
        cropQuad: DocumentQuad,
        thumbnail: UIImage,
        enhanceOverride: Bool? = nil,
        userLockedOrientation: Bool = false,
        manualRotationDegrees: CGFloat = 0,
        cachedAutoRotation: CGFloat? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.originalURL = originalURL
        self.cropQuad = cropQuad
        self.thumbnail = thumbnail
        self.enhanceOverride = enhanceOverride
        self.userLockedOrientation = userLockedOrientation
        self.manualRotationDegrees = manualRotationDegrees
        self.cachedAutoRotation = cachedAutoRotation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ScannedPage, rhs: ScannedPage) -> Bool {
        lhs.id == rhs.id && lhs.originalURL == rhs.originalURL
    }

    func usesEnhance(documentDefault: Bool) -> Bool {
        enhanceOverride ?? documentDefault
    }

    /// Rotation applied in every preview and in the PDF.
    var displayRotation: CGFloat {
        userLockedOrientation ? Self.normalized(manualRotationDegrees) : 0
    }

    func effectiveRotation(autoRotateEnabled: Bool) -> CGFloat {
        if userLockedOrientation {
            return Self.normalized(manualRotationDegrees)
        }
        if autoRotateEnabled {
            return Self.normalized(cachedAutoRotation ?? 0)
        }
        return 0
    }

    static func normalized(_ degrees: CGFloat) -> CGFloat {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        if value < 0.25 || value > 359.75 { return 0 }
        return value
    }
}

/// Full photo waiting for the user to adjust crop before it becomes a page.
struct PendingCapture {
    let photoURL: URL
    let displayImage: UIImage
    var quad: DocumentQuad
    /// When set, Keep replaces this page instead of appending a new one.
    var replacingPageID: UUID?
}
