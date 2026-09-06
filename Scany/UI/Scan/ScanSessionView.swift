import SwiftUI

struct ScanSessionView: View {
    @ObservedObject var model: ScanViewModel
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraLayer
            shutterFlash
            chrome
        }
        .statusBarHidden()
        .onAppear { model.startIfAuthorized() }
        .onDisappear { model.stop() }
        .alert("Discard this scan?", isPresented: $confirmCancel) {
            Button("Keep scanning", role: .cancel) {}
            Button("Discard", role: .destructive) {
                model.discardSession()
                onCancel()
            }
        } message: {
            Text("\(model.document.pages.count) page(s) will be deleted.")
        }
        .alert("Scan issue", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastErrorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastErrorMessage != nil },
            set: { if !$0 { model.lastErrorMessage = nil } }
        )
    }

    @ViewBuilder
    private var cameraLayer: some View {
        switch model.authorization {
        case .authorized:
            CameraPreviewView(
                session: model.camera,
                quad: model.quad,
                overlayColor: model.overlayColor,
                isStable: model.isOverlayStable
            )
            .ignoresSafeArea()
        case .denied, .restricted:
            permissionPlaceholder
        default:
            Color.black
        }
    }

    private var shutterFlash: some View {
        Color.white
            .opacity(model.showShutterFlash ? 0.55 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: model.showShutterFlash)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            guidanceChip
            thumbnailStrip
            bottomBar
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if model.document.pages.isEmpty {
                    model.discardSession()
                    onCancel()
                } else {
                    confirmCancel = true
                }
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)

            Spacer()

            pageCountBadge

            Spacer()

            Button(action: model.toggleTorch) {
                Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(model.isTorchOn ? ScanyTheme.accent : .white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var pageCountBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
            Text("\(model.document.pages.count)")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
        .accessibilityLabel("\(model.document.pages.count) pages captured")
    }

    private var guidanceChip: some View {
        HStack(spacing: 8) {
            Image(systemName: model.guidance.systemImage)
            Text(model.guidance.title)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .foregroundStyle(.white)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: model.guidance)
    }

    @ViewBuilder
    private var thumbnailStrip: some View {
        if !model.document.pages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.document.pages.enumerated()), id: \.element.id) { index, page in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: page.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                                    )

                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .padding(4)
                                    .background(.black.opacity(0.65), in: Circle())
                                    .foregroundStyle(.white)
                                    .offset(x: 4, y: -4)
                            }
                            .id(page.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.deletePage(id: page.id)
                                } label: {
                                    Label("Delete page", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scanyOnChange(of: model.document.pages.count) { _ in
                    if let last = model.document.pages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .trailing) }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Color.clear.frame(width: 72, height: 1)

            Spacer()

            Button(action: model.manualCapture) {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(model.isProcessingCapture ? ScanyTheme.accent : .white)
                        .frame(width: 62, height: 62)
                }
            }
            .disabled(model.isProcessingCapture)
            .accessibilityLabel("Capture page now")
            .opacity(0.95)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        if model.document.pages.isEmpty {
                            Capsule().fill(.ultraThinMaterial)
                        } else {
                            Capsule().fill(ScanyTheme.accent)
                        }
                    }
                    .foregroundStyle(model.document.pages.isEmpty ? .white.opacity(0.55) : ScanyTheme.ink)
            }
            .disabled(model.document.pages.isEmpty)
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
        .padding(.top, 6)
    }

    private var permissionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 42))
                .foregroundStyle(ScanyTheme.accent)
            Text("Scany needs the camera to scan pages.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Auto-detect, straighten, and capture happen live from the camera feed.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Open Settings", action: model.openSettings)
                .buttonStyle(.borderedProminent)
                .tint(ScanyTheme.accent)
                .foregroundStyle(ScanyTheme.ink)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
