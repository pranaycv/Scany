import AVFoundation
import CoreImage
import SwiftUI
import UIKit

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var document: ScanDocument
    @Published var quad: DocumentQuad?
    @Published var guidance: ScanGuidance = .searching
    @Published var isTorchOn = false
    @Published var showShutterFlash = false
    @Published var isProcessingCapture = false
    @Published var authorization: AVAuthorizationStatus
    @Published var lastErrorMessage: String?
    @Published var pendingCapture: PendingCapture?
    @Published var previewingPageID: UUID?
    @Published var isCommittingCapture = false
    @Published var isRefreshingPages = false

    private var cameraSession: CameraSession?
    private let attitude = DeviceAttitudeTracker()

    var camera: CameraSession {
        if let cameraSession { return cameraSession }
        let session = CameraSession()
        session.delegate = self
        cameraSession = session
        return session
    }

    private var stabilizer = QuadStabilizer()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()
    private var lastGoodQuad: DocumentQuad?
    private var lastGoodQuadDate: Date?
    private var isPreviewingPDF = false
    private var awaitingPageChange = false
    private var lastCapturedQuad: DocumentQuad?
    private var missingPageSince: Date?
    private var pendingDeviceRotation: CGFloat = 0
    private var pendingCapturedQuad: DocumentQuad?
    private var pageVisibleInFrame = false
    private var cachedPDF: CachedPDF?
    /// Next accepted capture replaces this page (after Retake on an existing page).
    private var pageReplacementID: UUID?
    private var previewCache: [UUID: UIImage] = [:]
    private var nextPageEnhance = false
    private var nextPageRotation: CGFloat = 0
    private var nextPageLockedOrientation = false

    init() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        document = ScanDocument(
            autoEnhanceAllPages: false,
            autoRotateAllPages: false,
            storageDirectory: FileManager.default.temporaryDirectory
        )
    }

    var overlayColor: UIColor {
        switch guidance {
        case .capturing, .captured:
            return ScanyTheme.accentUIColor
        case .holdSteady:
            return ScanyTheme.overlaySettlingUIColor
        case .searching:
            return UIColor.white
        default:
            return UIColor.white
        }
    }

    var isOverlayStable: Bool {
        guidance == .capturing || guidance == .holdSteady
    }

    /// Creates the session folder the first time the user opens the camera.
    func prepareSession() {
        let sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanySessions", isDirectory: true)
        if document.storageDirectory.path.hasPrefix(sessionsRoot.path) {
            return
        }
        resetForNewScan()
    }

    func startIfAuthorized() {
        switch authorization {
        case .authorized:
            camera.configureAndStart()
            attitude.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.authorization = granted ? .authorized : .denied
                    if granted {
                        self?.camera.configureAndStart()
                        self?.attitude.start()
                        self?.guidance = .searching
                    } else {
                        self?.guidance = .needCameraAccess
                    }
                }
            }
        case .denied, .restricted:
            guidance = .needCameraAccess
        @unknown default:
            guidance = .cameraUnavailable
        }
    }

    func stop() {
        isTorchOn = false
        attitude.stop()
        // Avoid allocating the capture session if the user never left Home.
        if let cameraSession {
            cameraSession.setTorch(enabled: false)
            cameraSession.stop()
        }
    }

    func toggleTorch() {
        isTorchOn.toggle()
        camera.setTorch(enabled: isTorchOn)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func deletePage(id: UUID) {
        if let page = document.pages.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: page.originalURL)
        }
        document.pages.removeAll { $0.id == id }
        previewCache[id] = nil
        invalidatePDFCache()
    }

    func movePages(from source: IndexSet, to destination: Int) {
        document.pages.move(fromOffsets: source, toOffset: destination)
        invalidatePDFCache()
    }

    func discardSession() {
        stop()
        document.removeFromDisk()
        invalidatePDFCache()
    }

    func clearLocalCopies() {
        document.removeFromDisk()
        document.pages = []
        invalidatePDFCache()
    }

    func resetForNewScan() {
        discardSession()
        let directory = (try? ScanDocument.makeSessionDirectory())
            ?? FileManager.default.temporaryDirectory
        document = ScanDocument(
            autoEnhanceAllPages: false,
            autoRotateAllPages: false,
            storageDirectory: directory
        )
        quad = nil
        guidance = authorization == .authorized ? .searching : .needCameraAccess
        isTorchOn = false
        showShutterFlash = false
        isProcessingCapture = false
        lastErrorMessage = nil
        lastGoodQuad = nil
        lastGoodQuadDate = nil
        isPreviewingPDF = false
        awaitingPageChange = false
        lastCapturedQuad = nil
        missingPageSince = nil
        pendingDeviceRotation = 0
        pendingCapturedQuad = nil
        pageVisibleInFrame = false
        discardPendingFile()
        pendingCapture = nil
        previewingPageID = nil
        isCommittingCapture = false
        pageReplacementID = nil
        nextPageEnhance = false
        nextPageRotation = 0
        nextPageLockedOrientation = false
        stabilizer.reset()
        previewCache = [:]
        invalidatePDFCache()
    }

    func manualCapture() {
        guard !isProcessingCapture, previewingPageID == nil, pendingCapture == nil, !isCommittingCapture else { return }
        triggerCapture()
    }

    func setPreviewingPDF(_ previewing: Bool) {
        isPreviewingPDF = previewing
        if previewing {
            stabilizer.reset()
        }
    }

    func exportPDF() async throws -> URL {
        var title = ScanDocument.makeExportFileName(
            title: document.title,
            appendDateTime: ScanPreferences.appendDateTimeToFileName
        )
        if title.isEmpty {
            title = "Scan"
        }
        let directory = document.storageDirectory
        let fingerprint = pdfFingerprint()
        if let cached = cachedPDF,
           cached.fingerprint == fingerprint,
           FileManager.default.fileExists(atPath: cached.url.path)
        {
            if cached.title == title {
                return cached.url
            }
            let renamed = directory.appendingPathComponent("\(sanitizedPDFFileName(title)).pdf")
            if renamed != cached.url {
                try? FileManager.default.removeItem(at: renamed)
                try FileManager.default.copyItem(at: cached.url, to: renamed)
            }
            cachedPDF = CachedPDF(fingerprint: fingerprint, title: title, url: renamed)
            return renamed
        }
        var images: [UIImage] = []
        images.reserveCapacity(document.pages.count)
        for page in document.pages {
            guard let image = await processedImage(for: page.id) else {
                throw PDFExportError.renderFailed
            }
            images.append(image)
        }
        let url = try PDFExporter.export(
            title: title,
            images: images,
            outputDirectory: directory
        )
        cachedPDF = CachedPDF(fingerprint: fingerprint, title: title, url: url)
        return url
    }

    func setDocumentTitle(_ title: String) {
        document.title = title
    }

    func applyAutoEnhanceToAllPages() {
        document.autoEnhanceAllPages = true
        ScanPreferences.autoEnhanceEnabled = true
        for index in document.pages.indices {
            document.pages[index].enhanceOverride = nil
        }
        invalidatePDFCache()
    }

    func disableAutoEnhance() {
        document.autoEnhanceAllPages = false
        ScanPreferences.autoEnhanceEnabled = false
        for index in document.pages.indices {
            document.pages[index].enhanceOverride = nil
        }
        invalidatePDFCache()
    }

    func applyAutoRotateToAllPages() async {
        document.autoRotateAllPages = true
        ScanPreferences.autoRotateEnabled = true
        isRefreshingPages = true
        defer { isRefreshingPages = false }
        for index in document.pages.indices where !document.pages[index].userLockedOrientation {
            document.pages[index].cachedAutoRotation = nil
        }
        await cacheMissingDeskewAngles()
        await refreshAllProcessedThumbnails()
        invalidatePDFCache()
    }

    func disableAutoRotate() {
        document.autoRotateAllPages = false
        ScanPreferences.autoRotateEnabled = false
        for index in document.pages.indices where !document.pages[index].userLockedOrientation {
            if let thumbnail = PageCaptureProcessor.makeThumbnail(
                photoURL: document.pages[index].originalURL,
                quad: document.pages[index].cropQuad
            ) {
                document.pages[index].thumbnail = thumbnail
            }
        }
        invalidatePDFCache()
    }

    func beginEditingPage(id: UUID) {
        guard previewingPageID == nil, pendingCapture == nil, !isCommittingCapture, !isProcessingCapture else { return }
        guard document.pages.contains(where: { $0.id == id }) else { return }
        previewingPageID = id
        presentCapturePreview()
    }

    func setPageEnhance(id: UUID, enabled: Bool) {
        guard let index = document.pages.firstIndex(where: { $0.id == id }) else { return }
        document.pages[index].enhanceOverride = enabled
        nextPageEnhance = enabled
        previewCache[id] = nil
        invalidatePDFCache()
        Task { await refreshProcessedThumbnail(for: id) }
    }

    func rotatePage(id: UUID, deltaDegrees: CGFloat) {
        guard let index = document.pages.firstIndex(where: { $0.id == id }) else { return }
        document.pages[index].userLockedOrientation = true
        document.pages[index].manualRotationDegrees = ScannedPage.normalized(
            document.pages[index].manualRotationDegrees + deltaDegrees
        )
        nextPageLockedOrientation = true
        nextPageRotation = document.pages[index].manualRotationDegrees
        previewCache[id] = nil
        invalidatePDFCache()
        Task { await refreshProcessedThumbnail(for: id) }
    }

    func cachedPreviewImage(for pageID: UUID) -> UIImage? {
        previewCache[pageID]
    }

    func dropPreviewCache(for pageID: UUID) {
        previewCache[pageID] = nil
    }

    func processedImage(for pageID: UUID) async -> UIImage? {
        guard let page = document.pages.first(where: { $0.id == pageID }) else { return nil }
        if let cached = previewCache[pageID] { return cached }
        let image = await renderPage(page)
        if let image { previewCache[pageID] = image }
        return image
    }

    /// One pipeline for capture preview, review, thumbnails, and PDF.
    private func renderPage(_ page: ScannedPage) async -> UIImage? {
        let url = page.originalURL
        let quad = page.cropQuad
        let enhance = page.usesEnhance(documentDefault: false)
        let rotation = page.displayRotation
        return await Task.detached(priority: .userInitiated) {
            PageCaptureProcessor.flattenedPreview(
                photoURL: url,
                quad: quad,
                enhance: enhance,
                rotationDegrees: rotation
            )
        }.value
    }

    var capturePreviewIndex: Int {
        if let id = previewingPageID,
           let index = document.pages.firstIndex(where: { $0.id == id })
        {
            return index
        }
        return max(document.pages.count - 1, 0)
    }

    func continueScanningFromPreview() {
        rememberAdjustmentsFromPreview()
        previewingPageID = nil
        pageReplacementID = nil
        awaitingPageChange = true
        lastCapturedQuad = pendingCapturedQuad
        missingPageSince = nil
        pageVisibleInFrame = false
        guidance = .searching
        startIfAuthorized()
    }

    func finishCapturePreview() {
        rememberAdjustmentsFromPreview()
        previewingPageID = nil
        pageReplacementID = nil
    }

    private func rememberAdjustmentsFromPreview() {
        guard let id = previewingPageID,
              let page = document.pages.first(where: { $0.id == id })
        else { return }
        nextPageEnhance = page.usesEnhance(documentDefault: false)
        nextPageLockedOrientation = page.userLockedOrientation
        nextPageRotation = page.displayRotation
    }

    func retakePreviewingPage() {
        guard !isCommittingCapture, let id = previewingPageID else { return }
        pageReplacementID = id
        previewingPageID = nil
        awaitingPageChange = false
        lastCapturedQuad = nil
        pendingCapturedQuad = nil
        isProcessingCapture = false
        pageVisibleInFrame = false
        guidance = .searching
        startIfAuthorized()
    }

    // MARK: - Capture

    private func considerAutoCapture() {
        guard authorization == .authorized else { return }
        guard !isProcessingCapture, !isPreviewingPDF else { return }
        guard pendingCapture == nil, previewingPageID == nil, !isCommittingCapture else { return }

        if blocksAutoCaptureUntilPageChanges() {
            if guidance != .capturing {
                guidance = .captured
            }
            return
        }

        if let current = quad, current.isPageRectangle {
            stabilizer.push(quad: current)
        } else {
            stabilizer.push(quad: nil)
        }

        switch stabilizer.evaluate() {
        case .noPage:
            if guidance != .captured {
                guidance = .searching
            }
        case .settling:
            guidance = .holdSteady
        case .ready:
            triggerCapture()
        }
    }

    /// One sheet should produce one photo. Auto-capture stays off while that
    /// same sheet is still in view, then arms again for a new page.
    private func blocksAutoCaptureUntilPageChanges() -> Bool {
        guard awaitingPageChange else { return false }

        if let current = quad, let last = lastCapturedQuad, current.isLikelySamePage(as: last) {
            missingPageSince = nil
            return true
        }

        if quad != nil {
            awaitingPageChange = false
            lastCapturedQuad = nil
            missingPageSince = nil
            stabilizer.reset()
            return false
        }

        if missingPageSince == nil {
            missingPageSince = Date()
        }
        if let start = missingPageSince, Date().timeIntervalSince(start) >= 0.35 {
            awaitingPageChange = false
            lastCapturedQuad = nil
            missingPageSince = nil
            stabilizer.reset()
            return false
        }
        return true
    }

    private func triggerCapture() {
        guard !isProcessingCapture, pendingCapture == nil, previewingPageID == nil else { return }
        isProcessingCapture = true
        guidance = .capturing
        pendingDeviceRotation = attitude.uprightRotationDegrees
        pendingCapturedQuad = lastGoodQuad ?? quad
        stabilizer.reset()
        haptic.prepare()
        playCaptureFeedback()
        camera.capturePhoto()
    }

    func updatePageCrop(id: UUID, quad: DocumentQuad, refreshThumbnail: Bool = false) {
        guard let index = document.pages.firstIndex(where: { $0.id == id }) else { return }
        document.pages[index].cropQuad = quad
        document.pages[index].cachedAutoRotation = nil
        previewCache[id] = nil
        invalidatePDFCache()
        guard refreshThumbnail else { return }
        let page = document.pages[index]
        let enhance = page.usesEnhance(documentDefault: false)
        let rotation = page.displayRotation
        if let image = PageCaptureProcessor.flattenedPreview(
            photoURL: page.originalURL,
            quad: quad,
            enhance: enhance,
            rotationDegrees: rotation
        ) {
            document.pages[index].thumbnail = Self.thumbnail(from: image)
        }
    }

    private func commitPreparedCapture(_ pending: PendingCapture) async -> UUID? {
        isCommittingCapture = true
        defer { isCommittingCapture = false }

        let replacingID = pending.replacingPageID ?? pageReplacementID
        var enhance = false
        var rotation: CGFloat = 0
        var lockedOrientation = false
        if let replacingID, let old = document.pages.first(where: { $0.id == replacingID }) {
            enhance = old.usesEnhance(documentDefault: false)
            rotation = old.displayRotation
            lockedOrientation = old.userLockedOrientation
        } else {
            enhance = nextPageEnhance
            rotation = nextPageRotation
            lockedOrientation = nextPageLockedOrientation
        }
        let preview = PageCaptureProcessor.flattenedPreview(
            photoURL: pending.photoURL,
            quad: pending.quad,
            enhance: enhance,
            rotationDegrees: rotation
        )
        let thumbnail = preview.map { Self.thumbnail(from: $0) } ?? pending.displayImage
        let pageID: UUID
        if let replacingID, let index = document.pages.firstIndex(where: { $0.id == replacingID }) {
            let old = document.pages[index]
            if old.originalURL != pending.photoURL {
                try? FileManager.default.removeItem(at: old.originalURL)
            }
            document.pages[index] = ScannedPage(
                id: old.id,
                createdAt: old.createdAt,
                originalURL: pending.photoURL,
                cropQuad: pending.quad,
                thumbnail: thumbnail,
                enhanceOverride: enhance,
                userLockedOrientation: lockedOrientation,
                manualRotationDegrees: rotation
            )
            pageID = old.id
        } else {
            document.pages.append(
                ScannedPage(
                    originalURL: pending.photoURL,
                    cropQuad: pending.quad,
                    thumbnail: thumbnail,
                    enhanceOverride: enhance,
                    userLockedOrientation: lockedOrientation,
                    manualRotationDegrees: rotation
                )
            )
            pageID = document.pages[document.pages.count - 1].id
        }
        if let preview { previewCache[pageID] = preview }
        pendingCapture = nil
        isProcessingCapture = false
        pageReplacementID = nil
        invalidatePDFCache()
        return pageID
    }

    @discardableResult
    private func finishPreparedCapture(_ pending: PendingCapture) async -> UUID? {
        pendingCapture = pending
        guard let pageID = await commitPreparedCapture(pending) else { return nil }
        previewingPageID = pageID
        presentCapturePreview()
        return pageID
    }

    private func discardPendingFile() {
        if let url = pendingCapture?.photoURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func presentCapturePreview() {
        guidance = .captured
        camera.setTorch(enabled: false)
        isTorchOn = false
        camera.stop()
        attitude.stop()
        stabilizer.reset()
        awaitingPageChange = true
        lastCapturedQuad = pendingCapturedQuad ?? lastGoodQuad ?? quad
        missingPageSince = nil
        lastGoodQuad = nil
        lastGoodQuadDate = nil
        quad = nil
    }

    /// Haptic and flash only. The system shutter sound already plays once.
    private func playCaptureFeedback() {
        showShutterFlash = true
        haptic.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.showShutterFlash = false
        }
    }

    private func handleDetection(quad: DocumentQuad?) {
        pageVisibleInFrame = quad != nil
        let accepted = quad.flatMap { $0.isPageRectangle ? $0 : nil }
        if awaitingPageChange {
            self.quad = accepted
        } else if let accepted {
            lastGoodQuad = accepted
            lastGoodQuadDate = Date()
            self.quad = accepted
        } else if let last = lastGoodQuad,
                  let date = lastGoodQuadDate,
                  Date().timeIntervalSince(date) < 0.18
        {
            self.quad = last
        } else {
            lastGoodQuad = nil
            self.quad = nil
        }
        considerAutoCapture()
    }

    private func invalidatePDFCache() {
        cachedPDF = nil
    }

    private func pdfFingerprint() -> String {
        document.pages.map { page in
            let corners = page.cropQuad.corners
                .map { "\($0.x.bitPattern)-\($0.y.bitPattern)" }
                .joined(separator: ",")
            let enhance = page.usesEnhance(documentDefault: false) ? "e" : "n"
            let rotation = page.displayRotation
            return "\(page.id.uuidString):\(corners):\(enhance):\(rotation)"
        }
        .joined(separator: "|")
    }

    private func sanitizedPDFFileName(_ title: String) -> String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
    }

    private func cacheMissingDeskewAngles() async {
        for page in document.pages where !page.userLockedOrientation && page.cachedAutoRotation == nil {
            await cacheDeskewAngle(for: page.id)
        }
    }

    private func cacheDeskewAngle(for pageID: UUID) async {
        guard let page = document.pages.first(where: { $0.id == pageID }),
              !page.userLockedOrientation,
              page.cachedAutoRotation == nil
        else { return }
        let url = page.originalURL
        let quad = page.cropQuad
        let angle = await Task.detached(priority: .utility) {
            guard let flattened = try? PageCaptureProcessor.flattenedImage(
                photoURL: url,
                quad: quad,
                enhance: false
            ) else { return CGFloat(0) }
            return PageDeskewer.alignmentDegrees(from: flattened)
        }.value
        if let index = document.pages.firstIndex(where: { $0.id == pageID }) {
            document.pages[index].cachedAutoRotation = angle
        }
    }

    private func refreshAllProcessedThumbnails() async {
        for page in document.pages {
            await refreshProcessedThumbnail(for: page.id)
        }
    }

    private func refreshProcessedThumbnail(for pageID: UUID) async {
        guard let image = await processedImage(for: pageID),
              let index = document.pages.firstIndex(where: { $0.id == pageID })
        else { return }
        document.pages[index].thumbnail = Self.thumbnail(from: image)
    }

    private static func thumbnail(from image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 240
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension ScanViewModel: CameraSessionDelegate {
    nonisolated func cameraSession(_ session: CameraSession, didDetect quad: DocumentQuad?) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleDetection(quad: quad)
            }
        } else {
            Task { @MainActor in
                self.handleDetection(quad: quad)
            }
        }
    }

    nonisolated func cameraSessionDidFinishPhoto(
        _ session: CameraSession,
        image: CIImage?,
        jpegData: Data?,
        detectedQuad: DocumentQuad?,
        fallbackQuad: DocumentQuad?
    ) {
        Task { @MainActor in
            guard let image else {
                self.isProcessingCapture = false
                self.guidance = .searching
                self.lastErrorMessage = "Capture failed. Try again."
                return
            }
            let preferred = detectedQuad ?? fallbackQuad
            let directory = self.document.storageDirectory
            let rotation = self.pendingDeviceRotation
            let replacingID = self.pageReplacementID
            Task.detached(priority: .userInitiated) {
                do {
                    var pending = try PageCaptureProcessor.preparePreview(
                        image: image,
                        preferredQuad: preferred,
                        directory: directory,
                        deviceRotationDegrees: rotation,
                        jpegData: jpegData
                    )
                    pending.replacingPageID = replacingID
                    await self.finishPreparedCapture(pending)
                } catch {
                    await MainActor.run {
                        self.lastErrorMessage = error.localizedDescription
                        self.isProcessingCapture = false
                        self.guidance = .searching
                        self.notify.notificationOccurred(.error)
                    }
                }
            }
        }
    }

    nonisolated func cameraSession(_ session: CameraSession, didFail error: Error) {
        Task { @MainActor in
            if self.document.pages.isEmpty {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CachedPDF {
    var fingerprint: String
    var title: String
    var url: URL
}
