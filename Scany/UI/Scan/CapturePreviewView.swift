import SwiftUI

struct CapturePreviewView: View {
    @ObservedObject var model: ScanViewModel
    var onFinish: () -> Void

    @State private var isCropping = false

    var body: some View {
        ZStack {
            ScanyTheme.ink.ignoresSafeArea()

            if model.previewingPageID != nil {
                VStack(spacing: 0) {
                    topBar
                    PagePreviewContent(
                        model: model,
                        pageID: pageIDBinding,
                        isCropping: $isCropping
                    )
                    if !isCropping {
                        bottomBar
                    }
                }
            } else {
                ProgressView()
                    .tint(ScanyTheme.accent)
            }

            if model.isCommittingCapture {
                Color.black.opacity(0.45).ignoresSafeArea()
                ProgressView("Saving page…")
                    .progressViewStyle(.circular)
                    .tint(ScanyTheme.accent)
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .statusBarHidden()
    }

    private var pageIDBinding: Binding<UUID> {
        Binding(
            get: { model.previewingPageID ?? UUID() },
            set: { model.previewingPageID = $0 }
        )
    }

    private var topBar: some View {
        ZStack {
            Text(isCropping ? "Adjust crop" : "Page \(model.capturePreviewIndex + 1)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            HStack {
                if isCropping {
                    Button {
                        isCropping = false
                    } label: {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .foregroundStyle(.white)
                }

                Spacer()

                Text("\(model.capturePreviewIndex + 1) / \(max(model.document.pages.count, 1))")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .opacity(isCropping ? 0 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: model.retakePreviewingPage) {
                    Text("Retake")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(model.isCommittingCapture)

                Button {
                    model.continueScanningFromPreview()
                } label: {
                    Text("Scan more")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ScanyTheme.accent, in: Capsule())
                        .foregroundStyle(ScanyTheme.ink)
                }
                .disabled(model.isCommittingCapture)
            }

            Button {
                model.finishCapturePreview()
                onFinish()
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(model.isCommittingCapture)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(Color.black.opacity(0.72))
    }
}
