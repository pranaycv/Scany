import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: CameraSession
    var quad: DocumentQuad?
    var overlayColor: UIColor
    var isStable: Bool

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.updateOverlay(quad: quad, color: overlayColor, emphasized: isStable)
    }
}

final class CameraPreviewUIView: UIView {
    private weak var camera: CameraSession?
    private let overlay = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let dim = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        dim.fillColor = UIColor.black.withAlphaComponent(0.28).cgColor
        dim.fillRule = .evenOdd
        layer.addSublayer(dim)

        fill.fillColor = ScanyTheme.accentUIColor.withAlphaComponent(0.12).cgColor
        layer.addSublayer(fill)

        overlay.fillColor = UIColor.clear.cgColor
        overlay.strokeColor = ScanyTheme.accentUIColor.cgColor
        overlay.lineWidth = 3
        overlay.lineJoin = .round
        overlay.lineCap = .round
        layer.addSublayer(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(session: CameraSession) {
        camera = session
        session.previewLayer.frame = bounds
        if session.previewLayer.superlayer !== layer {
            layer.insertSublayer(session.previewLayer, at: 0)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        camera?.previewLayer.frame = bounds
        overlay.frame = bounds
        fill.frame = bounds
        dim.frame = bounds
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let point = touches.first?.location(in: self) else { return }
        camera?.focus(at: point)
    }

    func updateOverlay(quad: DocumentQuad?, color: UIColor, emphasized: Bool) {
        guard let quad, quad.isPageRectangle, let camera else {
            overlay.path = nil
            fill.path = nil
            dim.path = nil
            return
        }

        // Keep the preview layer in sync before converting — SwiftUI can call
        // updateUIView before layoutSubviews on the first frame.
        camera.previewLayer.frame = bounds

        let displayQuad = quad.contracted(by: 0.012)
        let points = displayQuad.corners.map { camera.convertToLayer($0) }
        guard points.count == 4 else { return }

        let path = UIBezierPath()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.addLine(to: points[3])
        path.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.path = path.cgPath
        overlay.strokeColor = color.cgColor
        overlay.lineWidth = emphasized ? 4 : 3
        fill.path = path.cgPath
        fill.fillColor = color.withAlphaComponent(emphasized ? 0.18 : 0.10).cgColor

        let dimPath = UIBezierPath(rect: bounds)
        dimPath.append(path)
        dimPath.usesEvenOddFillRule = true
        dim.path = dimPath.cgPath
        CATransaction.commit()
    }
}
