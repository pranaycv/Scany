import SwiftUI
import UIKit

/// Full-photo crop editor. The image starts fit-to-screen; pinch to zoom and
/// drag the four handles to match the physical page.
struct CropEditorView: UIViewRepresentable {
    let image: UIImage
    @Binding var quad: DocumentQuad
    var onDragEnded: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(quad: $quad, onDragEnded: onDragEnded)
    }

    func makeUIView(context: Context) -> CropEditorUIView {
        let view = CropEditorUIView()
        view.onQuadChange = { context.coordinator.quad.wrappedValue = $0 }
        view.onDragEnded = { context.coordinator.onDragEnded?() }
        view.configure(image: image, quad: quad)
        return view
    }

    func updateUIView(_ uiView: CropEditorUIView, context: Context) {
        context.coordinator.onDragEnded = onDragEnded
        uiView.onDragEnded = { context.coordinator.onDragEnded?() }
        if uiView.image !== image {
            uiView.configure(image: image, quad: quad)
        } else if uiView.isDraggingHandle == false, uiView.quad != quad {
            uiView.quad = quad
            uiView.layoutHandles()
        }
    }

    final class Coordinator {
        var quad: Binding<DocumentQuad>
        var onDragEnded: (() -> Void)?
        init(quad: Binding<DocumentQuad>, onDragEnded: (() -> Void)?) {
            self.quad = quad
            self.onDragEnded = onDragEnded
        }
    }
}

final class CropEditorUIView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let loupeView = UIView()
    private let loupeImageView = UIImageView()
    private let loupeCrosshair = CAShapeLayer()
    private var handles: [UIView] = []

    private(set) var image: UIImage?
    var quad: DocumentQuad = .fallbackFullFrame()
    var onQuadChange: ((DocumentQuad) -> Void)?
    var onDragEnded: (() -> Void)?
    private(set) var isDraggingHandle = false
    private var hasFitted = false
    private let loupeSize: CGFloat = 148
    private let loupeSample: CGFloat = 110

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
        layer.addSublayer(dimLayer)

        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.strokeColor = ScanyTheme.accentUIColor.cgColor
        outlineLayer.lineWidth = 2.5
        outlineLayer.lineJoin = .round
        layer.addSublayer(outlineLayer)

        handles = (0..<4).map { index in
            let handle = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
            handle.backgroundColor = ScanyTheme.accentUIColor
            handle.layer.cornerRadius = 14
            handle.layer.borderWidth = 2
            handle.layer.borderColor = UIColor.white.cgColor
            handle.tag = index
            handle.isUserInteractionEnabled = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            handle.addGestureRecognizer(pan)
            addSubview(handle)
            return handle
        }

        loupeView.isHidden = true
        loupeView.isUserInteractionEnabled = false
        loupeView.bounds = CGRect(x: 0, y: 0, width: loupeSize, height: loupeSize)
        loupeView.layer.cornerRadius = loupeSize / 2
        loupeView.clipsToBounds = true
        loupeView.layer.borderWidth = 2.5
        loupeView.layer.borderColor = UIColor.white.cgColor
        loupeView.backgroundColor = .black
        loupeView.layer.shadowColor = UIColor.black.cgColor
        loupeView.layer.shadowOpacity = 0.45
        loupeView.layer.shadowRadius = 10
        loupeView.layer.shadowOffset = CGSize(width: 0, height: 4)
        loupeView.layer.masksToBounds = false
        loupeImageView.contentMode = .scaleAspectFill
        loupeImageView.frame = loupeView.bounds
        loupeImageView.layer.cornerRadius = loupeSize / 2
        loupeImageView.clipsToBounds = true
        loupeView.addSubview(loupeImageView)
        loupeCrosshair.strokeColor = ScanyTheme.accentUIColor.cgColor
        loupeCrosshair.fillColor = UIColor.clear.cgColor
        loupeCrosshair.lineWidth = 1.2
        loupeView.layer.addSublayer(loupeCrosshair)
        addSubview(loupeView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: UIImage, quad: DocumentQuad) {
        self.image = image
        self.quad = quad
        imageView.image = image
        hasFitted = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        dimLayer.frame = bounds
        outlineLayer.frame = bounds
        guard let image, bounds.width > 1, bounds.height > 1 else { return }
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        updateZoomScales(resetToFit: !hasFitted)
        hasFitted = true
        layoutHandles()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        layoutHandles()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutHandles()
    }

    func layoutHandles() {
        let rect = displayedImageRect()
        guard rect.width > 1, rect.height > 1 else { return }
        let points = quad.corners.map { viewPoint(for: $0, in: rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
        }
        outlineLayer.path = path.cgPath
        let dimPath = UIBezierPath(rect: bounds)
        dimPath.append(path)
        dimPath.usesEvenOddFillRule = true
        dimLayer.path = dimPath.cgPath
        CATransaction.commit()

        for (index, handle) in handles.enumerated() where index < points.count {
            handle.center = points[index]
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view else { return }
        switch gesture.state {
        case .began:
            isDraggingHandle = true
            scrollView.isScrollEnabled = false
            showLoupe(around: visionPoint(forHandle: handle.tag))
        case .changed:
            let location = gesture.location(in: self)
            let rect = displayedImageRect()
            var vision = visionPoint(for: location, in: rect)
            vision.x = min(max(vision.x, 0.01), 0.99)
            vision.y = min(max(vision.y, 0.01), 0.99)
            var next = quad
            switch handle.tag {
            case 0: next.topLeft = vision
            case 1: next.topRight = vision
            case 2: next.bottomRight = vision
            default: next.bottomLeft = vision
            }
            next = next.withBoundingBoxFromCorners()
            guard next.fillRatio >= 0.04 else { return }
            quad = next
            layoutHandles()
            onQuadChange?(next)
            showLoupe(around: vision)
        default:
            isDraggingHandle = false
            scrollView.isScrollEnabled = true
            hideLoupe()
            onDragEnded?()
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale * 1.05 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let target = min(scrollView.minimumZoomScale * 2.4, scrollView.maximumZoomScale)
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: scrollView.bounds.width / target,
                height: scrollView.bounds.height / target
            )
            let rect = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }

    private func updateZoomScales(resetToFit: Bool) {
        guard let image, bounds.width > 1, bounds.height > 1 else { return }
        let xScale = bounds.width / image.size.width
        let yScale = bounds.height / image.size.height
        let fit = min(xScale, yScale) * 0.96
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 8, 4)
        if resetToFit {
            scrollView.zoomScale = fit
        }
        centerImage()
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.size.width < boundsSize.width
            ? (boundsSize.width - frame.size.width) / 2
            : 0
        frame.origin.y = frame.size.height < boundsSize.height
            ? (boundsSize.height - frame.size.height) / 2
            : 0
        imageView.frame = frame
    }

    private func displayedImageRect() -> CGRect {
        imageView.convert(imageView.bounds, to: self)
    }

    private func visionPoint(forHandle index: Int) -> CGPoint {
        let pts = quad.corners
        guard pts.indices.contains(index) else { return CGPoint(x: 0.5, y: 0.5) }
        return pts[index]
    }

    private func showLoupe(around vision: CGPoint) {
        let documentRect = displayedImageRect()
        var center = CGPoint(x: documentRect.midX, y: documentRect.midY)
        if !bounds.insetBy(dx: loupeSize / 2, dy: loupeSize / 2).contains(center) {
            center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        loupeView.center = center
        loupeImageView.image = magnifiedPatch(around: vision)
        layoutLoupeCrosshair()
        loupeView.isHidden = false
        bringSubviewToFront(loupeView)
    }

    private func hideLoupe() {
        loupeView.isHidden = true
        loupeImageView.image = nil
    }

    private func layoutLoupeCrosshair() {
        let mid = CGPoint(x: loupeSize / 2, y: loupeSize / 2)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: mid.x - 18, y: mid.y))
        path.addLine(to: CGPoint(x: mid.x + 18, y: mid.y))
        path.move(to: CGPoint(x: mid.x, y: mid.y - 18))
        path.addLine(to: CGPoint(x: mid.x, y: mid.y + 18))
        path.append(UIBezierPath(ovalIn: CGRect(x: mid.x - 5, y: mid.y - 5, width: 10, height: 10)))
        loupeCrosshair.path = path.cgPath
        loupeCrosshair.frame = loupeView.bounds
    }

    private func magnifiedPatch(around vision: CGPoint) -> UIImage? {
        guard let image, let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let sample = min(max(loupeSample * image.scale, 80), min(width, height) * 0.35)
        let px = vision.x * width
        let py = (1 - vision.y) * height
        var crop = CGRect(
            x: px - sample / 2,
            y: py - sample / 2,
            width: sample,
            height: sample
        )
        crop.origin.x = min(max(crop.origin.x, 0), max(width - crop.width, 0))
        crop.origin.y = min(max(crop.origin.y, 0), max(height - crop.height, 0))
        crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isEmpty, let cropped = cgImage.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private func viewPoint(for vision: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + vision.x * imageRect.width,
            y: imageRect.minY + (1 - vision.y) * imageRect.height
        )
    }

    private func visionPoint(for view: CGPoint, in imageRect: CGRect) -> CGPoint {
        guard imageRect.width > 1, imageRect.height > 1 else { return .zero }
        return CGPoint(
            x: (view.x - imageRect.minX) / imageRect.width,
            y: 1 - (view.y - imageRect.minY) / imageRect.height
        )
    }
}
