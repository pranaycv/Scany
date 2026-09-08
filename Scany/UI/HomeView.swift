import SwiftUI

struct HomeView: View {
    @ObservedObject var cloud: CloudManager
    var onStartScan: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.14),
                    Color(red: 0.08, green: 0.12, blue: 0.22)
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
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: ScanyTheme.accent.opacity(0.35), radius: 16, y: 6)

                    Text("Scany")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    VStack(spacing: 8) {
                        Text("Cloud-first PDF")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Save to Google Drive or iCloud, then clear the local pages.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                }

                Spacer()

                cloudStatus
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

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
        if cloud.google == nil && cloud.iCloud == nil {
            Button(action: onOpenSettings) {
                Label("Connect Drive or iCloud", systemImage: "icloud")
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
                if let iCloud = cloud.iCloud {
                    statusChip(
                        title: iCloud.folder?.name ?? "iCloud",
                        subtitle: iCloud.isSimulated ? "Sim" : iCloud.account.email
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
}
