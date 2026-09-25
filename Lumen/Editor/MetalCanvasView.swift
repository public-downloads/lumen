import CoreImage
import MetalKit
import SwiftUI

/// Draws a `CIImage` into an `MTKView` on the GPU. Redraws only when the image
/// changes, so idle cost is zero.
struct MetalCanvasView: UIViewRepresentable {
    let image: CIImage?

    func makeCoordinator() -> Renderer { Renderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false          // CIContext writes into the drawable
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        view.setNeedsDisplay()
    }

    final class Renderer: NSObject, MTKViewDelegate {
        /// Apple's Core Image + MTKView samples render without flipping. If the
        /// preview shows upside down on device, set this to true.
        private let flipVertically = false

        let device = MTLCreateSystemDefaultDevice()
        private lazy var queue = device?.makeCommandQueue()
        private lazy var ciContext: CIContext? = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        var image: CIImage?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let queue, let ciContext, let image,
                  let commandBuffer = queue.makeCommandBuffer() else { return }

            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            guard bounds.width > 1, bounds.height > 1,
                  image.extent.width > 0, image.extent.height > 0 else { return }

            let scale = min(bounds.width / image.extent.width,
                            bounds.height / image.extent.height)
            var fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            fitted = fitted.transformed(by: CGAffineTransform(
                translationX: ((bounds.width - fitted.extent.width) / 2 - fitted.extent.minX).rounded(),
                y: ((bounds.height - fitted.extent.height) / 2 - fitted.extent.minY).rounded()))

            if flipVertically {
                fitted = fitted
                    .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                    .transformed(by: CGAffineTransform(translationX: 0, y: bounds.height))
            }

            let composited = fitted.composited(over: CIImage(color: .black).cropped(to: bounds))

            ciContext.render(composited,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: bounds,
                             colorSpace: colorSpace)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
