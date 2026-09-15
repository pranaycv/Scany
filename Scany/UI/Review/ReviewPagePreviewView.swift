import SwiftUI
import UIKit

/// Review-time page editor: processed preview with enhance, rotate, and crop.
struct ReviewPagePreviewView: View {
    @ObservedObject var model: ScanViewModel
    @Binding var pageID: UUID

    @State private var isCropping = false

    private var pageIndex: Int? {
        model.document.pages.firstIndex(where: { $0.id == pageID })
    }

    var body: some View {
        PagePreviewContent(
            model: model,
            pageID: $pageID,
            isCropping: $isCropping
        )
        .navigationTitle(isCropping ? "Adjust crop" : pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .scanyToolbarChrome()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isCropping {
                    Button("Done") {
                        isCropping = false
                    }
                    .foregroundStyle(ScanyTheme.accent)
                }
            }
        }
    }

    private var pageTitle: String {
        if let pageIndex {
            return "Page \(pageIndex + 1)"
        }
        return "Page"
    }
}

/// Flattened page preview: fit-to-screen, pinch to zoom, enhance / rotate / crop.
struct PagePreviewContent: View {
    @ObservedObject var model: ScanViewModel
    @Binding var pageID: UUID
    @Binding var isCropping: Bool
#if DEBUG
    @EnvironmentObject private var cloud: CloudManager
#endif

    @State private var processed: UIImage?
    @State private var original: UIImage?
    @State private var isLoading = true
#if DEBUG
    @State private var isSavingTrain = false
    @State private var trainToast: String?
    @State private var trainError: String?
#endif

    private var pageIndex: Int? {
        model.document.pages.firstIndex(where: { $0.id == pageID })
    }

    private var page: ScannedPage? {
        model.document.pages.first(where: { $0.id == pageID })
    }

    private var enhanceOn: Bool {
        page?.usesEnhance(documentDefault: false) ?? false
    }

    private var canGoPrevious: Bool {
        (pageIndex ?? 0) > 0
    }

    private var canGoNext: Bool {
        guard let pageIndex else { return false }
        return pageIndex + 1 < model.document.pages.count
    }

    var body: some View {
        ZStack {
            ScanyTheme.ink.ignoresSafeArea()
            if isCropping, let original, pageIndex != nil {
                cropEditor(original: original)
            } else if let processed {
                processedPreview(processed)
            } else if isLoading {
                ProgressView()
                    .tint(ScanyTheme.accent)
            } else {
                Text("Could not load this page.")
                    .foregroundStyle(.white)
            }

            if model.document.pages.count > 1, !isLoading, !isCropping {
                PageStepButtons(
                    canGoPrevious: canGoPrevious,
                    canGoNext: canGoNext,
                    onPrevious: { go(delta: -1) },
                    onNext: { go(delta: 1) }
                )
            }

#if DEBUG
            if let trainToast {
                VStack {
                    Text(trainToast)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScanyTheme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(ScanyTheme.accent, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
#endif
        }
        .task(id: pageID) { await loadInitial() }
#if DEBUG
        .task(id: trainToast) {
            guard trainToast != nil else { return }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            trainToast = nil
        }
        .alert("Could not add to train", isPresented: Binding(
            get: { trainError != nil },
            set: { if !$0 { trainError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trainError ?? "")
        }
#endif
        .scanyOnChange(of: isCropping) { cropping in
            if !cropping {
                Task { await reloadProcessed() }
            }
        }
    }

    private func processedPreview(_ image: UIImage) -> some View {
        ZStack {
            ZoomableImageView(image: image)
                .ignoresSafeArea(edges: .horizontal)

            VStack {
                Spacer()
                overlayBar
            }
        }
    }

    private var overlayBar: some View {
        HStack(spacing: 10) {
            overlayButton(
                title: "Enhance",
                systemImage: "wand.and.stars",
                emphasized: enhanceOn
            ) {
                model.setPageEnhance(id: pageID, enabled: !enhanceOn)
                Task { await reloadProcessed() }
            }
            overlayButton(title: "Rotate", systemImage: "rotate.right") {
                model.rotatePage(id: pageID, deltaDegrees: 90)
                Task { await reloadProcessed() }
            }
            overlayButton(title: "Crop", systemImage: "crop") {
                Task { await openCrop() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private func overlayButton(
        title: String,
        systemImage: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(emphasized ? ScanyTheme.ink : .white)
            .background(
                emphasized ? ScanyTheme.process : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private func cropEditor(original: UIImage) -> some View {
        VStack(spacing: 0) {
            CropEditorView(
                image: original,
                quad: cropBinding,
                onDragEnded: {
                    if let page {
                        model.updatePageCrop(id: pageID, quad: page.cropQuad, refreshThumbnail: true)
                    }
                }
            )
            VStack(spacing: 10) {
                Text("Drag the corners to match the page. Pinch to zoom.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
#if DEBUG
                Button(action: addToTrain) {
                    HStack(spacing: 8) {
                        if isSavingTrain {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(ScanyTheme.ink)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("Add to train")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ScanyTheme.accent, in: Capsule())
                    .foregroundStyle(ScanyTheme.ink)
                }
                .disabled(isSavingTrain || page == nil)
#endif
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.72))
        }
    }

    private var cropBinding: Binding<DocumentQuad> {
        Binding(
            get: { page?.cropQuad ?? .fallbackFullFrame() },
            set: { model.updatePageCrop(id: pageID, quad: $0) }
        )
    }

    private func go(delta: Int) {
        guard let pageIndex else { return }
        let target = pageIndex + delta
        guard model.document.pages.indices.contains(target) else { return }
        isCropping = false
        original = nil
        processed = nil
        isLoading = true
        pageID = model.document.pages[target].id
    }

    private func loadInitial() async {
        isCropping = false
        original = nil
        if let cached = model.cachedPreviewImage(for: pageID) {
            processed = cached
            isLoading = false
            return
        }
        isLoading = true
        await reloadProcessed()
        isLoading = processed == nil
    }

    private func reloadProcessed() async {
        processed = await model.processedImage(for: pageID)
    }

    private func openCrop() async {
        if original == nil, let page {
            original = await Task.detached(priority: .userInitiated) {
                PageCaptureProcessor.displayImage(from: page.originalURL)
            }.value
        }
        if original != nil {
            isCropping = true
        }
    }

#if DEBUG
    private func addToTrain() {
        guard let page else { return }
        trainError = nil
        isSavingTrain = true
        let imageURL = page.originalURL
        let quad = page.cropQuad
        Task {
            defer { isSavingTrain = false }
            do {
                let result = try await cloud.uploadTrainingSample(imageURL: imageURL, quad: quad)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                trainToast = TrainingExport.successMessage(provider: result.provider)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                trainError = error.localizedDescription
            }
        }
    }
#endif
}
