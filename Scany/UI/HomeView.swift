import SwiftUI

struct HomeView: View {
    var onStartScan: () -> Void

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

                    Text("Point at a page. Hold still. Scany captures it, straightens it, and keeps going until you tap Done.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 12) {
                    featureRow(icon: "viewfinder", title: "Live page detect", subtitle: "Vision finds the paper in any orientation.")
                    featureRow(icon: "camera.metering.center.weighted", title: "Stabilize & auto-capture", subtitle: "No shutter tap required for each page.")
                    featureRow(icon: "wand.and.stars", title: "Enhance + PDF", subtitle: "Clean up the whole document, then share.")
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
