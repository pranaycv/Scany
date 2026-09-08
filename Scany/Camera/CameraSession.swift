import AVFoundation
import CoreImage
import ImageIO
import UIKit

protocol CameraSessionDelegate: AnyObject {
    func cameraSession(_ session: CameraSession, didDetect quad: DocumentQuad?)
    func cameraSessionDidFinishPhoto(
        _ session: CameraSession,
        image: CIImage?,
        jpegData: Data?,
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
    private lazy var detector = DocumentDetector()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?

    private var isVisionBusy = false
    private var lastVideoQuad: DocumentQuad?
    private var isConfigured = false
    private var isCapturingPhoto = false
    private var skipVisionFrame = 0

    var isRunning: Bool { session.isRunning }

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureLocked()
            self.isCapturingPhoto = false
            self.isVisionBusy = false
            self.skipVisionFrame = 0
            self.applyPortraitOrientation()
            self.session.startRunning()
            self.applyPortraitOrientation()
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
            guard !self.isCapturingPhoto else { return }
            self.isCapturingPhoto = true
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            if self.photoOutput.isStillImageStabilizationSupported {
                settings.isAutoStillImageStabilizationEnabled = true
            }
            if #available(iOS 16.0, *) {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            } else {
                settings.isHighResolutionPhotoEnabled = self.photoOutput.isHighResolutionCaptureEnabled
            }
            settings.photoQualityPrioritization = .quality
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

    /// Maps a Vision point (normalized, origin bottom-left, in the *oriented*
    /// image) onto the preview layer, including `.resizeAspectFill` cropping.
    ///
    /// Capture-device points are the unrotated sensor. Using those with a
    /// portrait video buffer makes the overlay larger than the paper. Metadata
    /// output rects match the picture on screen.
    func convertToLayer(_ visionPoint: CGPoint) -> CGPoint {
        let imageRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let x = visionPoint.x
        let y = 1 - visionPoint.y
        return CGPoint(
            x: imageRect.minX + x * imageRect.width,
            y: imageRect.minY + y * imageRect.height
        )
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

        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if #available(iOS 16.0, *) {
            let dimensions = camera.activeFormat.supportedMaxPhotoDimensions
            if let largest = dimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photoOutput.maxPhotoDimensions = largest
            }
        } else {
            photoOutput.isHighResolutionCaptureEnabled = true
        }

        applyPortraitOrientation()
        configureDevice(camera)

        session.commitConfiguration()
        isConfigured = true
    }

    /// Back camera buffers are landscape unless the connection rotated them.
    /// Vision's `orientation` must match so results land in portrait display space.
    private static func visionOrientation(for pixelBuffer: CVPixelBuffer) -> CGImagePropertyOrientation {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width > height {
            return .right
        }
        return .up
    }

    private func bestPreset() -> AVCaptureSession.Preset {
        if session.canSetSessionPreset(.photo) {
            return .photo
        }
        if session.canSetSessionPreset(.hd4K3840x2160) {
            return .hd4K3840x2160
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

    /// Keep the camera JPEG; avoid a full-size CI round-trip that softens the page.
    private static func materializedImage(from photo: AVCapturePhoto) -> (CIImage, Data?)? {
        guard let data = photo.fileDataRepresentation() else {
            if let pixelBuffer = photo.pixelBuffer {
                return (CIImage(cvPixelBuffer: pixelBuffer), nil)
            }
            return nil
        }
        let image = CIImage(data: data, options: [.applyOrientationProperty: true])
            ?? CIImage(data: data)
        guard let image else { return nil }
        return (image, data)
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isVisionBusy, !isCapturingPhoto else { return }
        skipVisionFrame += 1
        guard skipVisionFrame % 2 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isVisionBusy = true
        let orientation = Self.visionOrientation(for: pixelBuffer)
        let quad = detector.detect(pixelBuffer: pixelBuffer, orientation: orientation)
        lastVideoQuad = quad
        isVisionBusy = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.cameraSession(self, didDetect: quad)
        }
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let materialized = error == nil ? Self.materializedImage(from: photo) : nil
        let ciImage = materialized?.0
        let jpegData = materialized?.1
        visionQueue.async { [weak self] in
            guard let self else { return }
            let fallback = self.lastVideoQuad
            let detected = ciImage.flatMap { self.detector.detect(ciImage: $0, orientation: .up) }
            DispatchQueue.main.async {
                self.delegate?.cameraSessionDidFinishPhoto(
                    self,
                    image: ciImage,
                    jpegData: jpegData,
                    detectedQuad: detected,
                    fallbackQuad: fallback
                )
                self.sessionQueue.async {
                    self.isCapturingPhoto = false
                }
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
