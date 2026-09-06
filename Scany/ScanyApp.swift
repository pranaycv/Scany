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
    @StateObject private var cloud = CloudManager()
    @State private var route: AppRoute = .home
    @State private var showSettings = false

    var body: some View {
        Group {
            switch route {
            case .home:
                HomeView(
                    cloud: cloud,
                    onStartScan: { route = .scanning },
                    onOpenSettings: { showSettings = true }
                )
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
                    cloud: cloud,
                    onRescan: { route = .scanning },
                    onHome: {
                        startFreshSession()
                        route = .home
                    },
                    onOpenSettings: { showSettings = true }
                )
            }
        }
        .environmentObject(cloud)
        .onOpenURL { url in
            _ = cloud.handleOpenURL(url)
        }
        .sheet(isPresented: $showSettings) {
            CloudSettingsView(cloud: cloud, onClose: { showSettings = false })
        }
    }

    private func startFreshSession() {
        scanModel.resetForNewScan()
    }
}
