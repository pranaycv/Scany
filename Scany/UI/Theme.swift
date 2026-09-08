import SwiftUI
import UIKit

enum ScanyTheme {
    /// Logo blue sampled from Scany.png (91, 159, 224).
    static let accent = Color(red: 91 / 255, green: 159 / 255, blue: 224 / 255)
    static let accentDeep = Color(red: 40 / 255, green: 90 / 255, blue: 168 / 255)
    static let ink = Color(red: 0.07, green: 0.09, blue: 0.14)
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.38)

    static let overlaySearching = Color.white.opacity(0.85)
    static let overlaySettling = Color(red: 1.0, green: 0.84, blue: 0.28)
    static let overlayReady = accent
    /// Toggles that change how pages look (enhance / rotate).
    static let process = Color(red: 1.0, green: 0.55, blue: 0.22)
    static let processUIColor = UIColor(red: 1.0, green: 0.55, blue: 0.22, alpha: 1)

    /// UIKit colors — do not use `UIColor(Color)`, which is iOS 17+ only.
    static let accentUIColor = UIColor(red: 91 / 255, green: 159 / 255, blue: 224 / 255, alpha: 1)
    static let overlaySettlingUIColor = UIColor(red: 1.0, green: 0.84, blue: 0.28, alpha: 1)
}

enum ScanGuidance: Equatable {
    case needCameraAccess
    case cameraUnavailable
    case searching
    case holdSteady
    case capturing
    case captured

    var title: String {
        switch self {
        case .needCameraAccess: return "Camera access needed"
        case .cameraUnavailable: return "Camera unavailable"
        case .searching: return "Point at the page — it scans automatically"
        case .holdSteady: return "Page locked — capturing…"
        case .capturing: return "Capturing"
        case .captured: return "Page added — point at the next page"
        }
    }

    var systemImage: String {
        switch self {
        case .needCameraAccess, .cameraUnavailable: return "camera.fill"
        case .searching: return "doc.viewfinder"
        case .holdSteady: return "viewfinder"
        case .capturing: return "camera.fill"
        case .captured: return "checkmark.circle.fill"
        }
    }
}

struct PageStepButtons: View {
    var canGoPrevious: Bool
    var canGoNext: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack {
            stepButton(systemImage: "chevron.left", enabled: canGoPrevious, action: onPrevious)
            Spacer()
            stepButton(systemImage: "chevron.right", enabled: canGoNext, action: onNext)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(true)
    }

    private func stepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(enabled ? 0.45 : 0.2), in: Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(systemImage == "chevron.left" ? "Previous page" : "Next page")
    }
}
