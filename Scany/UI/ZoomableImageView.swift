import SwiftUI
import UIKit

/// Pinch-to-zoom image. Zoom scale 1 is always fit-to-view; pinch zooms in.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var backgroundColor: UIColor = UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)

    func makeUIView(context: Context) -> ZoomableImageUIView {
        let view = ZoomableImageUIView()
        view.backgroundColor = backgroundColor
        view.setImage(image)
        return view
    }

    func updateUIView(_ uiView: ZoomableImageUIView, context: Context) {
        uiView.backgroundColor = backgroundColor
        if uiView.image !== image {
            uiView.setImage(image)
        }
    }
}

final class ZoomableImageUIView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private(set) var image: UIImage?
    private var userHasZoomed = false
    private var isPinching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        self.image = image
        imageView.image = image
        userHasZoomed = false
        isPinching = false
        if bounds.width > 1, bounds.height > 1 {
            layoutImage(resetToFit: true)
        } else {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard image != nil, bounds.width > 1, bounds.height > 1 else { return }
        if isPinching {
            centerImage()
            return
        }
        layoutImage(resetToFit: !userHasZoomed)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isPinching = true
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        userHasZoomed = scrollView.zoomScale > 1.02
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        isPinching = false
        userHasZoomed = scale > 1.02
    }

    private func layoutImage(resetToFit: Bool) {
        guard let image, bounds.width > 1, bounds.height > 1 else { return }
        let fitted = Self.aspectFit(image.size, in: bounds.size)
        let keepZoom = resetToFit ? 1 : min(max(scrollView.zoomScale, 1), 8)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.zoomScale = keepZoom
        if resetToFit {
            userHasZoomed = false
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

    private static func aspectFit(_ imageSize: CGSize, in bounds: CGSize) -> CGSize {
        let width = max(imageSize.width, 1)
        let height = max(imageSize.height, 1)
        let scale = min(bounds.width / width, bounds.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.05 {
            userHasZoomed = false
            scrollView.setZoomScale(1, animated: true)
        } else {
            userHasZoomed = true
            let target: CGFloat = 2.4
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
}
