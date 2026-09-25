import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Turns a `MaskSpec` into a CIImage suitable for `CIBlendWithMask`.
///
/// Every path ends in `CIMaskToAlpha`, which makes alpha track luminance.
/// `CIBlendWithMask` keys off alpha, so a plain white-to-black gradient (alpha 1
/// everywhere) would otherwise blend the whole frame at full strength.
final class MaskRenderer {

    private var brushCache: [UUID: (key: String, image: CIImage)] = [:]

    func invalidate() { brushCache.removeAll() }

    func image(for spec: MaskSpec,
               layerID: UUID,
               extent: CGRect,
               source: CIImage,
               subjectMask: CIImage?,
               opacity: Float) -> CIImage? {

        var gray: CIImage?

        switch spec.kind {
        case .whole:
            gray = CIImage(color: .white).cropped(to: extent)
        case .radial:
            gray = radial(spec, extent: extent)
        case .linear:
            gray = linear(spec, extent: extent)
        case .brush:
            gray = brush(spec, layerID: layerID, extent: extent)
        case .subject:
            gray = subjectMask?.resized(to: extent)
        case .luminance:
            gray = luminance(spec, source: source, extent: extent)
        }

        guard var mask = gray else { return nil }

        if spec.inverted {
            mask = mask.applyingFilter("CIColorInvert")
        }

        if opacity < 1 {
            let scale = CGFloat(max(0, opacity))
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }

        return mask.applyingFilter("CIMaskToAlpha").cropped(to: extent)
    }

    // MARK: - Shapes

    // Gradients are *generators*: they have no inputImage, so they must be built
    // through CIFilter rather than CIImage.applyingFilter.

    private func radial(_ spec: MaskSpec, extent: CGRect) -> CIImage {
        let minDim = min(extent.width, extent.height)
        let center = CGPoint(x: extent.minX + spec.center.x * extent.width,
                             y: extent.minY + (1 - spec.center.y) * extent.height)
        let outer = max(spec.radius * minDim, 1)
        let inner = outer * CGFloat(1 - min(max(spec.feather, 0.01), 0.99))

        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(inner)
        filter.radius1 = Float(outer)
        filter.color0 = .white
        filter.color1 = .black

        return filter.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
    }

    private func linear(_ spec: MaskSpec, extent: CGRect) -> CIImage {
        let radians = spec.angle * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: sin(radians))
        let diagonal = hypot(extent.width, extent.height)
        let mid = CGPoint(x: extent.midX + direction.dx * (spec.position - 0.5) * diagonal,
                          y: extent.midY + direction.dy * (spec.position - 0.5) * diagonal)
        let half = max(CGFloat(spec.feather), 0.01) * diagonal * 0.5

        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: mid.x - direction.dx * half, y: mid.y - direction.dy * half)
        filter.point1 = CGPoint(x: mid.x + direction.dx * half, y: mid.y + direction.dy * half)
        filter.color0 = .white
        filter.color1 = .black

        return filter.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
    }

    private func luminance(_ spec: MaskSpec, source: CIImage, extent: CGRect) -> CIImage {
        let gray = source.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1, kCIInputBrightnessKey: 0,
        ])
        let softness = max(CGFloat(spec.feather) * 0.25, 0.02)

        // Two clamped linear ramps; their minimum is a soft band pass.
        let up = ramp(gray, edge: CGFloat(spec.lumaLow), softness: softness, rising: true)
        let down = ramp(gray, edge: CGFloat(spec.lumaHigh), softness: softness, rising: false)

        return up.applyingFilter("CIMinimumCompositing", parameters: [
            kCIInputBackgroundImageKey: down,
        ]).cropped(to: extent)
    }

    private func ramp(_ gray: CIImage, edge: CGFloat, softness: CGFloat, rising: Bool) -> CIImage {
        let scale = (rising ? 1 : -1) / (2 * softness)
        let bias = rising ? -(edge - softness) * scale : 1 - (edge - softness) * scale

        return gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    // MARK: - Brush

    private func brush(_ spec: MaskSpec, layerID: UUID, extent: CGRect) -> CIImage? {
        let key = spec.brushCacheKey
        if let cached = brushCache[layerID], cached.key == key { return cached.image }

        // Rasterise small — the mask gets blurred anyway, so upscaling is free.
        let longest = max(extent.width, extent.height)
        let rasterScale = min(1, 1200 / max(longest, 1))
        let width = max(Int(extent.width * rasterScale), 8)
        let height = max(Int(extent.height * rasterScale), 8)

        guard let cgImage = rasterize(strokes: spec.strokes, width: width, height: height) else {
            return nil
        }

        let blurRadius = max(Double(spec.feather) * Double(width) * 0.03, 0.5)
        var image = CIImage(cgImage: cgImage)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let up = CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                   y: extent.height / CGFloat(height))
        image = image.transformed(by: up)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)

        brushCache[layerID] = (key, image)
        return image
    }

    /// Draws strokes white-on-black into a grayscale bitmap. CGContext and Core
    /// Image share a bottom-left origin, so only the incoming normalized `y`
    /// (top-down, from the gesture) needs flipping.
    private func rasterize(strokes: [BrushStroke], width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let w = CGFloat(width)
        let h = CGFloat(height)

        for stroke in strokes where !stroke.points.isEmpty {
            context.setStrokeColor(gray: stroke.erase ? 0 : 1, alpha: 1)
            context.setLineWidth(max(stroke.radius * 2 * w, 1))

            let mapped = stroke.points.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }
            context.beginPath()
            context.move(to: mapped[0])
            if mapped.count == 1 {
                context.addLine(to: CGPoint(x: mapped[0].x + 0.01, y: mapped[0].y))
            } else {
                for point in mapped.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()
        }

        return context.makeImage()
    }
}

extension CIImage {
    /// Scales this image so its extent matches `target` exactly.
    func resized(to target: CGRect) -> CIImage {
        guard extent.width > 0, extent.height > 0 else { return self }
        let scaled = transformed(by: CGAffineTransform(scaleX: target.width / extent.width,
                                                       y: target.height / extent.height))
        return scaled
            .transformed(by: CGAffineTransform(translationX: target.minX - scaled.extent.minX,
                                               y: target.minY - scaled.extent.minY))
            .cropped(to: target)
    }
}
