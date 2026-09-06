import AVFoundation
import CoreImage
import ImageIO
import UIKit

protocol CameraSessionDelegate: AnyObject {
    func cameraSession(
        _ session: CameraSession,
        didDetect quad: DocumentQuad?,
        sharpness: Double,
        luminance: Double
    )
    func cameraSessionDidFinishPhoto(
        _ session: CameraSession,
        image: CIImage?,
        detectedQuad: DocumentQuad?,
        fallbackQuad: DocumentQuad?
    )
    func cameraSession(_ session: CameraSession, didFail error: Error)
}

/// Custom AVFoundation pipeline: live preview, Vision on video frames, high-res stills.
final class CameraSession: NSObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    weak var delegate: CameraSessionDelegate?

    private let sessionQueue = DispatchQueue(label: "com.scany.camera.session")
    private let visionQueue = DispatchQueue(label: "com.scany.camera.vision", qos: .userInitiated)
    private let detector = DocumentDetector()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?

    private var isVisionBusy = false
    private var lastVideoQuad: DocumentQuad?
    private var isConfigured = false

    var isRunning: Bool { session.isRunning }

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            self?.configureLocked()
            self?.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func setTorch(enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if enabled, device.isTorchModeSupported(.on) {
                    try device.setTorchModeOn(level: 0.7)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            settings.photoQualityPrioritization = .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func focus(at layerPoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let devicePoint = self.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                device.unlockForConfiguration()
            }

            // Return to continuous AF so stabilize-and-capture keeps working.
            self.sessionQueue.asyncAfter(deadline: .now() + 1.6) { [weak device] in
                guard let device else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                } catch {
                    device.unlockForConfiguration()
                }
            }
        }
    }

    func convertToLayer(_ visionPoint: CGPoint) -> CGPoint {
        // Vision: origin bottom-left. Capture device points: origin top-left.
        let devicePoint = CGPoint(x: visionPoint.x, y: 1 - visionPoint.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }

    // MARK: - Setup

    private func configureLocked() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = bestPreset()

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.delegate?.cameraSession(self, didFail: CameraSessionError.noCamera)
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                videoDeviceInput = input
                device = camera
            }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.delegate?.cameraSession(self, didFail: error)
            }
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        photoOutput.maxPhotoQualityPrioritization = .balanced
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        applyPortraitOrientation()
        configureDevice(camera)

        session.commitConfiguration()
        isConfigured = true
    }

    private func bestPreset() -> AVCaptureSession.Preset {
        if session.canSetSessionPreset(.hd4K3840x2160) {
            return .hd4K3840x2160
        }
        if session.canSetSessionPreset(.photo) {
            return .photo
        }
        return .hd1920x1080
    }

    private func configureDevice(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = true
            }
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = .near
            }
            camera.unlockForConfiguration()
        } catch {
            camera.unlockForConfiguration()
        }
    }

    private func applyPortraitOrientation() {
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = false
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    /// Copy pixels out of the photo so later queues never touch a reused buffer.
    private static func materializedImage(from photo: AVCapturePhoto) -> CIImage? {
        var image: CIImage?
        if let data = photo.fileDataRepresentation() {
            image = CIImage(data: data)
        } else if let pixelBuffer = photo.pixelBuffer {
            image = CIImage(cvPixelBuffer: pixelBuffer)
        }
        guard var image else { return nil }

        if let orientationValue = image.properties[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: orientationValue)
        {
            image = image.oriented(orientation)
        } else if let orientationValue = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32,
                  let orientation = CGImagePropertyOrientation(rawValue: orientationValue)
        {
            image = image.oriented(orientation)
        }

        guard let cgImage = ScanImageFactory.context.createCGImage(image, from: image.extent) else {
            return image
        }
        return CIImage(cgImage: cgImage)
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isVisionBusy else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isVisionBusy = true
        let sharpness = FrameQuality.laplacianVariance(pixelBuffer: pixelBuffer)
        let luminance = FrameQuality.meanLuminance(pixelBuffer: pixelBuffer)
        let quad = detector.detect(pixelBuffer: pixelBuffer, orientation: .up)
        lastVideoQuad = quad
        isVisionBusy = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraSession(self, didDetect: quad, sharpness: sharpness, luminance: luminance)
        }
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let ciImage = error == nil ? Self.materializedImage(from: photo) : nil
        visionQueue.async { [weak self] in
            guard let self else { return }
            let fallback = self.lastVideoQuad
            let detected = ciImage.flatMap { self.detector.detect(ciImage: $0, orientation: .up) }
            DispatchQueue.main.async {
                self.delegate?.cameraSessionDidFinishPhoto(
                    self,
                    image: ciImage,
                    detectedQuad: detected,
                    fallbackQuad: fallback
                )
            }
        }
    }
}

enum CameraSessionError: LocalizedError {
    case noCamera

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "Scany could not find a camera on this device."
        }
    }
}
