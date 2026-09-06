import SwiftUI

struct HomeView: View {
    @ObservedObject var cloud: CloudManager
    var onStartScan: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.08, green: 0.14, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(ScanyTheme.accent.opacity(0.14))
                            .frame(width: 108, height: 108)
                        Image(systemName: "doc.viewfinder.fill")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(ScanyTheme.accent)
                    }

                    Text("Scany")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Point at a page. Hold still. Scany captures it, straightens it, and uploads the PDF to Drive or OneDrive. Nothing is kept as a local library.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer()

                cloudStatus
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 12) {
                    featureRow(icon: "viewfinder", title: "Live page detect", subtitle: "Vision finds the paper in any orientation.")
                    featureRow(icon: "camera.metering.center.weighted", title: "Stabilize & auto-capture", subtitle: "No shutter tap required for each page.")
                    featureRow(icon: "externaldrive.badge.icloud", title: "Cloud-first PDF", subtitle: "Save to Google Drive or OneDrive, then clear local pages.")
                }
                .padding(20)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 20)

                Button(action: onStartScan) {
                    Label("Start scan", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(ScanyTheme.accent, in: Capsule())
                        .foregroundStyle(ScanyTheme.ink)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var cloudStatus: some View {
        if cloud.google == nil && cloud.oneDrive == nil {
            Button(action: onOpenSettings) {
                Label("Connect Drive or OneDrive", systemImage: "cloud")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.white)
            }
        } else {
            HStack(spacing: 8) {
                if let google = cloud.google {
                    statusChip(
                        title: google.folder?.name ?? "Drive",
                        subtitle: google.isSimulated ? "Sim" : google.account.email
                    )
                }
                if let oneDrive = cloud.oneDrive {
                    statusChip(
                        title: oneDrive.folder?.name ?? "OneDrive",
                        subtitle: oneDrive.isSimulated ? "Sim" : oneDrive.account.email
                    )
                }
            }
        }
    }

    private func statusChip(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(ScanyTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }
}
