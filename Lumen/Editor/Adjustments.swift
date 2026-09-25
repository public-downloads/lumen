import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// One set of tonal/colour edits. Used both for the whole image and, inside an
/// `AdjustmentLayer`, for a masked region.
struct Adjustments: Equatable {
    var exposure: Float = 0        // EV, -4…4
    var contrast: Float = 0        // -1…1
    var blacks: Float = 0          // -1…1  ("darkness" at the bottom of the curve)
    var shadows: Float = 0         // -1…1
    var highlights: Float = 0      // -1…1
    var whites: Float = 0          // -1…1
    var saturation: Float = 0      // -1…1
    var vibrance: Float = 0        // -1…1
    var temperature: Float = 0     // -1…1  (right = warmer)
    var tint: Float = 0            // -1…1  (right = magenta)
    var clarity: Float = 0         // -1…1
    var sharpness: Float = 0       //  0…1
    var blur: Float = 0            //  0…1

    static let neutral = Adjustments()
    var isNeutral: Bool { self == .neutral }

    func apply(to input: CIImage) -> CIImage {
        guard !isNeutral else { return input }
        let extent = input.extent
        var image = input

        if exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }

        if temperature != 0 || tint != 0 {
            // Raising inputNeutral tells the filter the scene was lit by a bluer
            // source, so it adds warmth. Flip the sign here if it feels inverted.
            let kelvin = 6500 + CGFloat(temperature) * 3500
            let tintShift = CGFloat(tint) * 120
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: kelvin, y: tintShift),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }

        if blacks != 0 || shadows != 0 || highlights != 0 || whites != 0 {
            image = image.applyingFilter("CIToneCurve", parameters: toneCurvePoints())
        }

        if contrast != 0 || saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + contrast * 0.6,
                kCIInputSaturationKey: max(0, 1 + saturation),
                kCIInputBrightnessKey: 0,
            ])
        }

        if vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance])
        }

        // Filters below sample outside their pixel, so clamp first and crop back
        // or the frame picks up transparent edges.
        if clarity != 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 18.0,
                    kCIInputIntensityKey: clarity * 0.9,
                ])
                .cropped(to: extent)
        }

        if sharpness > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": sharpness * 1.5,
                    kCIInputRadiusKey: 1.8,
                ])
                .cropped(to: extent)
        }

        if blur > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * 40])
                .cropped(to: extent)
        }

        return image
    }

    /// Five spline points. `blacks`/`whites` move the endpoints (clipping),
    /// `shadows`/`highlights` move the quarter tones (lifting).
    private func toneCurvePoints() -> [String: Any] {
        var p0 = CGPoint(x: 0, y: 0)
        var p4 = CGPoint(x: 1, y: 1)

        if blacks < 0 {
            p0 = CGPoint(x: CGFloat(-blacks) * 0.15, y: 0)      // crush
        } else {
            p0 = CGPoint(x: 0, y: CGFloat(blacks) * 0.20)       // lift
        }

        if whites > 0 {
            p4 = CGPoint(x: 1 - CGFloat(whites) * 0.15, y: 1)   // blow out sooner
        } else {
            p4 = CGPoint(x: 1, y: 1 + CGFloat(whites) * 0.20)   // recover
        }

        var p1 = CGPoint(x: 0.25, y: 0.25 + CGFloat(shadows) * 0.20)
        let p2 = CGPoint(x: 0.5, y: 0.5)
        var p3 = CGPoint(x: 0.75, y: 0.75 + CGFloat(highlights) * 0.20)

        // Keep the curve monotonically increasing; a dip produces solarisation.
        p1.y = min(max(p1.y, p0.y + 0.01), p2.y - 0.01)
        p3.y = min(max(p3.y, p2.y + 0.01), p4.y - 0.01)

        return [
            "inputPoint0": CIVector(cgPoint: p0),
            "inputPoint1": CIVector(cgPoint: p1),
            "inputPoint2": CIVector(cgPoint: p2),
            "inputPoint3": CIVector(cgPoint: p3),
            "inputPoint4": CIVector(cgPoint: p4),
        ]
    }
}
