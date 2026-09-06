import SwiftUI

@main
struct ScanyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

enum AppRoute: Equatable {
    case home
    case scanning
    case review
}

struct RootView: View {
    @StateObject private var scanModel = ScanViewModel()
    @State private var route: AppRoute = .home

    var body: some View {
        switch route {
        case .home:
            HomeView {
                route = .scanning
            }
        case .scanning:
            ScanSessionView(
                model: scanModel,
                onCancel: {
                    startFreshSession()
                    route = .home
                },
                onDone: {
                    scanModel.stop()
                    route = .review
                }
            )
        case .review:
            ReviewView(
                model: scanModel,
                onRescan: {
                    route = .scanning
                },
                onHome: {
                    startFreshSession()
                    route = .home
                }
            )
        }
    }

    private func startFreshSession() {
        scanModel.resetForNewScan()
    }
}
