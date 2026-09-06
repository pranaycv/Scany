import AVFoundation
import AudioToolbox
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

    let camera = CameraSession()

    private var stabilizer = QuadStabilizer()
    private var latestSharpness: Double = 0
    private var latestLuminance: Double = 0
    private var isDebouncing = false
    private var debounceWork: DispatchWorkItem?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    /// Ignore auto-capture for this long after each page so we don't double-shoot.
    private let captureCooldown: TimeInterval = 1.35

    init() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let directory = (try? ScanDocument.makeSessionDirectory())
            ?? FileManager.default.temporaryDirectory
        document = ScanDocument(storageDirectory: directory)
        camera.delegate = self
    }

    var overlayColor: UIColor {
        switch guidance {
        case .capturing, .captured:
            return ScanyTheme.accentUIColor
        case .holdSteady:
            return ScanyTheme.overlaySettlingUIColor
        case .searching, .moveCloser, .lowLight, .tooBlurry:
            return UIColor.white
        default:
            return UIColor.white
        }
    }

    var isOverlayStable: Bool {
        guidance == .capturing || guidance == .holdSteady
    }

    func startIfAuthorized() {
        switch authorization {
        case .authorized:
            camera.configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.authorization = granted ? .authorized : .denied
                    if granted {
                        self?.camera.configureAndStart()
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
        camera.setTorch(enabled: false)
        isTorchOn = false
        camera.stop()
        debounceWork?.cancel()
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
            if let enhanced = page.enhancedURL {
                try? FileManager.default.removeItem(at: enhanced)
            }
        }
        document.pages.removeAll { $0.id == id }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        document.pages.move(fromOffsets: source, toOffset: destination)
    }

    func discardSession() {
        stop()
        document.removeFromDisk()
    }

    func clearLocalCopies() {
        document.removeFromDisk()
        document.pages = []
    }

    func resetForNewScan() {
        discardSession()
        let directory = (try? ScanDocument.makeSessionDirectory())
            ?? FileManager.default.temporaryDirectory
        document = ScanDocument(storageDirectory: directory)
        quad = nil
        guidance = authorization == .authorized ? .searching : .needCameraAccess
        isTorchOn = false
        showShutterFlash = false
        isProcessingCapture = false
        isDebouncing = false
        lastErrorMessage = nil
        stabilizer.reset()
        debounceWork?.cancel()
    }

    func manualCapture() {
        guard !isProcessingCapture, !isDebouncing else { return }
        triggerCapture()
    }

    func applyAutoEnhanceToAllPages() async {
        document.autoEnhanceAllPages = true
        for index in document.pages.indices {
            if document.pages[index].enhancedURL != nil { continue }
            await enhancePage(at: index)
        }
    }

    func disableAutoEnhance() {
        document.autoEnhanceAllPages = false
    }

    // MARK: - Capture

    private func considerAutoCapture() {
        guard authorization == .authorized else { return }
        guard !isProcessingCapture, !isDebouncing else { return }

        stabilizer.push(
            quad: quad,
            sharpness: latestSharpness,
            luminance: latestLuminance
        )

        if stabilizer.isLowLight, quad != nil {
            guidance = .lowLight
        }

        switch stabilizer.evaluate() {
        case .noPage:
            guidance = .searching
        case .tooSmall:
            guidance = .moveCloser
        case .blurry:
            guidance = .tooBlurry
        case .settling:
            if !stabilizer.isLowLight {
                guidance = .holdSteady
            }
        case .ready:
            triggerCapture()
        }
    }

    private func triggerCapture() {
        isProcessingCapture = true
        guidance = .capturing
        stabilizer.reset()
        haptic.prepare()
        camera.capturePhoto()
    }

    private func finishSuccessfulCapture() {
        playShutterFeedback()
        guidance = .captured
        isProcessingCapture = false
        isDebouncing = true
        stabilizer.reset()
        quad = nil

        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.isDebouncing = false
                if self?.guidance == .captured {
                    self?.guidance = .searching
                }
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + captureCooldown, execute: work)
    }

    private func playShutterFeedback() {
        showShutterFlash = true
        haptic.impactOccurred()
        AudioServicesPlaySystemSound(1108)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            self?.showShutterFlash = false
        }
    }

    private func enhancePage(at index: Int) async {
        guard document.pages.indices.contains(index) else { return }
        let page = document.pages[index]
        guard let ciImage = ScanImageFactory.ciImage(from: page.originalURL) else { return }
        if let url = ScanImageFactory.writeEnhanced(ciImage, id: page.id, directory: document.storageDirectory) {
            document.pages[index].enhancedURL = url
        }
    }
}

extension ScanViewModel: CameraSessionDelegate {
    nonisolated func cameraSession(
        _ session: CameraSession,
        didDetect quad: DocumentQuad?,
        sharpness: Double,
        luminance: Double
    ) {
        Task { @MainActor in
            self.latestSharpness = sharpness
            self.latestLuminance = luminance
            self.quad = quad
            self.considerAutoCapture()
        }
    }

    nonisolated func cameraSessionDidFinishPhoto(
        _ session: CameraSession,
        image: CIImage?,
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
            let autoEnhance = self.document.autoEnhanceAllPages
            Task.detached(priority: .userInitiated) {
                do {
                    let page = try PageCaptureProcessor.process(
                        image: image,
                        preferredQuad: preferred,
                        autoEnhance: autoEnhance,
                        directory: directory
                    )
                    await MainActor.run {
                        self.document.pages.append(page)
                        self.finishSuccessfulCapture()
                    }
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
