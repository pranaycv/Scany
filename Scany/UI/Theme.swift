import SwiftUI

enum ScanyTheme {
    static let accent = Color(red: 0.18, green: 0.82, blue: 0.72)
    static let accentDeep = Color(red: 0.07, green: 0.62, blue: 0.58)
    static let ink = Color(red: 0.07, green: 0.09, blue: 0.14)
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)

    static let overlaySearching = Color.white.opacity(0.85)
    static let overlaySettling = Color(red: 1.0, green: 0.84, blue: 0.28)
    static let overlayReady = accent
}

enum ScanGuidance: Equatable {
    case needCameraAccess
    case cameraUnavailable
    case searching
    case moveCloser
    case holdSteady
    case lowLight
    case tooBlurry
    case capturing
    case captured

    var title: String {
        switch self {
        case .needCameraAccess: return "Camera access needed"
        case .cameraUnavailable: return "Camera unavailable"
        case .searching: return "Position the page in the frame"
        case .moveCloser: return "Move closer to the page"
        case .holdSteady: return "Hold steady…"
        case .lowLight: return "Low light — add more light"
        case .tooBlurry: return "Hold still until it looks sharp"
        case .capturing: return "Capturing"
        case .captured: return "Page added — next page when ready"
        }
    }

    var systemImage: String {
        switch self {
        case .needCameraAccess, .cameraUnavailable: return "camera.fill"
        case .searching: return "doc.viewfinder"
        case .moveCloser: return "arrow.up.left.and.arrow.down.right"
        case .holdSteady: return "hand.raised.fill"
        case .lowLight: return "lightbulb"
        case .tooBlurry: return "camera.metering.none"
        case .capturing: return "camera.aperture"
        case .captured: return "checkmark.circle.fill"
        }
    }
}
