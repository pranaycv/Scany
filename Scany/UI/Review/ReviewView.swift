import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: ScanViewModel
    @ObservedObject var cloud: CloudManager
    var onRescan: () -> Void
    var onHome: () -> Void
    var onOpenSettings: () -> Void

    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var selectedPageID: UUID?
    @State private var showShare = false
    @State private var folderProvider: CloudProvider?
    @State private var uploadResult: CloudUploadResult?
    @State private var showUploadSuccess = false
    @State private var showPDFPreview = false
    @State private var confirmDiscard = false
    @FocusState private var isEditingFileName: Bool
    @AppStorage("scany.appendDateTimeToFileName") private var appendDateTime = false
    @State private var selectedSaveProvider: CloudProvider?

    private var isPagePresented: Binding<Bool> {
        Binding(
            get: { selectedPageID != nil },
            set: { if !$0 { selectedPageID = nil } }
        )
    }

    var body: some View {
        navigationContainer {
            ZStack {
                ScanyTheme.ink.ignoresSafeArea()

                if model.document.pages.isEmpty {
                    emptyState
                } else {
                    pageList
                }

                if isExporting || model.isRefreshingPages {
                    processingOverlay
                }
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .scanyToolbarChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Home") {
                        if model.document.pages.isEmpty {
                            onHome()
                        } else {
                            confirmDiscard = true
                        }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditingFileName = false }
                        .foregroundStyle(ScanyTheme.accent)
                }
            }
            .alert("Discard this scan?", isPresented: $confirmDiscard) {
                Button("Keep pages", role: .cancel) {}
                Button("Discard", role: .destructive, action: onHome)
            } message: {
                Text("\(model.document.pages.count) page(s) will be deleted.")
            }
            .safeAreaInset(edge: .bottom) {
                if !isEditingFileName {
                    bottomActions
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportURL = exportURL {
                    ActivityShareSheet(items: [exportURL])
                }
            }
            .sheet(isPresented: $showPDFPreview) {
                if let exportURL {
                    PDFPreviewView(url: exportURL, title: "Document preview") {
                        showPDFPreview = false
                    }
                }
            }
            .sheet(item: $folderProvider) { provider in
                CloudFolderPickerView(cloud: cloud, provider: provider)
            }
            .alert("Could not export", isPresented: Binding(
                get: { exportError != nil && !showUploadSuccess },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            .background(uploadSuccessAlert)
            .background(ios15PushLink)
            .scanyNavigationDestination(isPresented: isPagePresented) {
                pagePreview
            }
            .onAppear { syncSelectedProvider() }
            .scanyOnChange(of: cloud.readyProviders.map(\.id).joined()) { _ in
                syncSelectedProvider()
            }
        }
    }

    private var uploadSuccessAlert: some View {
        EmptyView()
            .alert("Uploaded", isPresented: $showUploadSuccess) {
                Button("Clear local copies") {
                    model.clearLocalCopies()
                    uploadResult = nil
                    onHome()
                }
                Button("Keep scanning", role: .cancel) {
                    uploadResult = nil
                }
            } message: {
                Text(uploadSuccessMessage)
            }
    }

    private var uploadSuccessMessage: String {
        guard let uploadResult else { return "The PDF is in your cloud folder." }
        let place = uploadResult.isSimulated
            ? "the sandbox folder \(uploadResult.folderName)"
            : "\(uploadResult.folderName) on \(uploadResult.provider.displayName)"
        return "\(uploadResult.fileName) is in \(place). Local page images can be cleared — Scany does not keep a document library."
    }

    @ViewBuilder
    private func navigationContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }

    /// `NavigationLink(isActive:)` is the iOS 15 push path. iOS 16+ uses
    /// `navigationDestination(isPresented:)` instead.
    @ViewBuilder
    private var ios15PushLink: some View {
        if #available(iOS 16.0, *) {
            EmptyView()
        } else {
            NavigationLink(destination: pagePreview, isActive: isPagePresented) {
                EmptyView()
            }
            .hidden()
        }
    }

    @ViewBuilder
    private var pagePreview: some View {
        if let id = selectedPageID {
            ReviewPagePreviewView(
                model: model,
                pageID: Binding(
                    get: { selectedPageID ?? id },
                    set: { selectedPageID = $0 }
                )
            )
        } else {
            Text("Page unavailable")
                .foregroundStyle(.white)
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
        VStack(spacing: 0) {
            fileNameBar
            dateTimeRow
            destinationRow
            List {
                ForEach(Array(model.document.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        selectedPageID = page.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(uiImage: page.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                            Text("Page \(index + 1)")
                                .font(.headline)
                                .foregroundStyle(.white)
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
            }
            .scanyHideListBackground()
            .listStyle(.plain)
        }
    }

    private var fileNameBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(ScanyTheme.accent)
                TextField("File name", text: titleBinding)
                    .foregroundColor(.white)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .submitLabel(.done)
                    .focused($isEditingFileName)
                    .onSubmit { isEditingFileName = false }
                Text(".pdf")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !exportFileName.isEmpty {
                Text("\(exportFileName).pdf")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var dateTimeRow: some View {
        Toggle("Add date and time", isOn: $appendDateTime)
            .tint(ScanyTheme.accent)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var destinationRow: some View {
        if cloud.readyProviders.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 8) {
                    ForEach(cloud.readyProviders) { provider in
                        Button {
                            selectedSaveProvider = provider
                        } label: {
                            Label(provider.displayName, systemImage: provider.systemImage)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    selectedSaveProvider == provider
                                        ? ScanyTheme.accent
                                        : Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .foregroundStyle(selectedSaveProvider == provider ? ScanyTheme.ink : .white)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var exportFileName: String {
        ScanDocument.makeExportFileName(
            title: model.document.title,
            appendDateTime: appendDateTime
        )
    }

    private var canSaveToCloud: Bool {
        !model.document.pages.isEmpty && !isExporting && !exportFileName.isEmpty
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.document.title },
            set: { model.setDocumentTitle($0) }
        )
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(ScanyTheme.accent)
                    .scaleEffect(1.2)
                Text(model.isRefreshingPages ? "Straightening pages…" : "Preparing PDF…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .allowsHitTesting(true)
    }

    private var bottomActions: some View {
        VStack(spacing: 8) {
            Button {
                Task { await handlePrimarySave() }
            } label: {
                label(primarySaveTitle, systemImage: "externaldrive.badge.icloud")
                    .background(ScanyTheme.accent, in: Capsule())
                    .foregroundStyle(ScanyTheme.ink)
            }
            .disabled(!canSaveToCloud)

            if !model.document.pages.isEmpty && exportFileName.isEmpty {
                Text("Enter a file name or turn on Add date and time.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 8) {
                compactAction("Preview", systemImage: "doc.text.magnifyingglass") {
                    Task { await previewPDF() }
                }
                .disabled(model.document.pages.isEmpty || isExporting)

                compactAction("Share", systemImage: "square.and.arrow.up") {
                    Task { await sharePDF() }
                }
                .disabled(model.document.pages.isEmpty || isExporting)

                compactAction("Scan more", systemImage: "plus.viewfinder") {
                    onRescan()
                }
                .disabled(isExporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func label(_ title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func compactAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
        }
    }

    private var primarySaveTitle: String {
        if cloud.readyProviders.count > 1, let selectedSaveProvider {
            return selectedSaveProvider.saveActionTitle
        }
        if let provider = cloud.preferredUploadProvider {
            return provider.saveActionTitle
        }
        if !cloud.connectedProviders.isEmpty {
            return "Choose a folder"
        }
        return "Connect cloud to save"
    }

    private func syncSelectedProvider() {
        let ready = cloud.readyProviders
        if let selectedSaveProvider, ready.contains(selectedSaveProvider) {
            return
        }
        selectedSaveProvider = cloud.preferredUploadProvider ?? ready.first
    }

    private func handlePrimarySave() async {
        if cloud.readyProviders.isEmpty {
            if let connected = cloud.connectedProviders.first {
                folderProvider = connected
                return
            }
            onOpenSettings()
            return
        }
        guard canSaveToCloud else {
            exportError = "Enter a file name or turn on Add date and time."
            return
        }
        if cloud.readyProviders.count > 1 {
            let provider = selectedSaveProvider ?? cloud.preferredUploadProvider ?? cloud.readyProviders[0]
            selectedSaveProvider = provider
            await saveToCloud(provider)
            return
        }
        if let provider = cloud.readyProviders.first {
            await saveToCloud(provider)
        }
    }

    private func saveToCloud(_ provider: CloudProvider) async {
        isExporting = true
        defer { isExporting = false }
        do {
            let pdf = try await model.exportPDF()
            exportURL = pdf
            let result = try await cloud.upload(
                pdfURL: pdf,
                filename: pdf.lastPathComponent,
                provider: provider
            )
            uploadResult = result
            showUploadSuccess = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func sharePDF() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await model.exportPDF()
            exportURL = url
            showShare = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func previewPDF() async {
        isExporting = true
        defer { isExporting = false }
        do {
            exportURL = try await model.exportPDF()
            showPDFPreview = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}
