import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: ScanViewModel
    var onRescan: () -> Void
    var onHome: () -> Void

    @State private var isEnhancing = false
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var selectedPageID: UUID?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScanyTheme.ink.ignoresSafeArea()

                if model.document.pages.isEmpty {
                    emptyState
                } else {
                    pageList
                }
            }
            .navigationTitle(model.document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Home", action: onHome)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .disabled(model.document.pages.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomActions }
            .sheet(isPresented: $showShare) {
                if let exportURL {
                    ActivityShareSheet(items: [exportURL])
                }
            }
            .alert("Could not export", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .navigationDestination(item: $selectedPageID) { id in
                if let page = model.document.pages.first(where: { $0.id == id }) {
                    PagePreviewView(page: page, enhanced: model.document.autoEnhanceAllPages)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(ScanyTheme.accent)
            Text("No pages yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Button("Back to camera", action: onRescan)
                .buttonStyle(.borderedProminent)
                .tint(ScanyTheme.accent)
                .foregroundStyle(ScanyTheme.ink)
        }
    }

    private var pageList: some View {
        List {
            Section {
                enhanceCard
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            Section("Pages") {
                ForEach(Array(model.document.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        selectedPageID = page.id
                    } label: {
                        HStack(spacing: 14) {
                            Image(uiImage: page.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Page \(index + 1)")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text(page.enhancedURL != nil && model.document.autoEnhanceAllPages
                                     ? "Enhanced"
                                     : "Original")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.document.pages[$0].id }
                    ids.forEach { model.deletePage(id: $0) }
                }
                .onMove(perform: model.movePages)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    private var enhanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(ScanyTheme.accent)
                Text("Auto-enhance")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            Text("Boost contrast and sharpness on every page. Turn it on once — Scany applies it to this whole document, including pages you capture next.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                model.document.autoEnhanceAllPages ? "Enhancement on for all pages" : "Auto-enhance all pages",
                isOn: enhanceBinding
            )
            .tint(ScanyTheme.accent)
            .foregroundStyle(.white)
            .disabled(isEnhancing)

            if isEnhancing {
                ProgressView("Enhancing pages…")
                    .progressViewStyle(.circular)
                    .tint(ScanyTheme.accent)
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var enhanceBinding: Binding<Bool> {
        Binding(
            get: { model.document.autoEnhanceAllPages },
            set: { enabled in
                if enabled {
                    isEnhancing = true
                    Task {
                        await model.applyAutoEnhanceToAllPages()
                        isEnhancing = false
                    }
                } else {
                    model.disableAutoEnhance()
                }
            }
        )
    }

    private var bottomActions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await exportPDF() }
            } label: {
                HStack {
                    if isExporting {
                        ProgressView().tint(ScanyTheme.ink)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isExporting ? "Building PDF…" : "Export PDF")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ScanyTheme.accent, in: Capsule())
                .foregroundStyle(ScanyTheme.ink)
            }
            .disabled(model.document.pages.isEmpty || isExporting)

            Button("Scan more pages", action: onRescan)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScanyTheme.accent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func exportPDF() async {
        isExporting = true
        defer { isExporting = false }
        let title = model.document.title
        let directory = model.document.storageDirectory
        let pageURLs: [URL] = model.document.pages.map { page in
            (model.document.autoEnhanceAllPages ? page.enhancedURL : nil) ?? page.originalURL
        }
        do {
            let url = try await Task.detached {
                try PDFExporter.export(
                    title: title,
                    pageImageURLs: pageURLs,
                    outputDirectory: directory
                )
            }.value
            exportURL = url
            showShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

struct PagePreviewView: View {
    let page: ScannedPage
    let enhanced: Bool

    var body: some View {
        ZStack {
            ScanyTheme.ink.ignoresSafeArea()
            if let image = page.displayImage(enhanced: enhanced) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            } else {
                Text("Could not load this page.")
                    .foregroundStyle(.white)
            }
        }
        .navigationTitle("Page")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
