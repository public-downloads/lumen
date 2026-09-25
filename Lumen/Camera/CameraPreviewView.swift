import AVFoundation
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer`. Taps are reported once, with both the
/// device point (for focus/metering) and the view point (for the indicator) —
/// adding a second SwiftUI tap gesture on top would fight this recogniser.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap

        let tap = UITapGestureRecognizer(target: view, action: #selector(PreviewUIView.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onTap = onTap
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint, CGPoint) -> Void)?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(devicePoint, point)
        }
    }
}
