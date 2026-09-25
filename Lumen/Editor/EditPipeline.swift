import CoreImage
import Foundation

enum EditPipeline {

    /// Global adjustments first, then each enabled layer composited back over the
    /// running result through its own mask.
    static func render(base: CIImage,
                       edit: Edit,
                       renderer: MaskRenderer,
                       subjectMask: CIImage?) -> CIImage {
        let extent = base.extent
        var result = edit.global.apply(to: base)

        for layer in edit.layers where layer.isEnabled {
            if layer.adjustments.isNeutral { continue }
            let adjusted = layer.adjustments.apply(to: result)
            guard let mask = renderer.image(for: layer.mask,
                                            layerID: layer.id,
                                            extent: extent,
                                            source: base,
                                            subjectMask: subjectMask,
                                            opacity: layer.opacity) else { continue }
            result = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: mask,
            ])
        }

        return result.cropped(to: extent)
    }

    /// Semi-transparent red wash showing where a layer's mask is active.
    static func maskOverlay(over image: CIImage,
                            layer: AdjustmentLayer,
                            base: CIImage,
                            renderer: MaskRenderer,
                            subjectMask: CIImage?) -> CIImage {
        let extent = base.extent
        guard let mask = renderer.image(for: layer.mask,
                                        layerID: layer.id,
                                        extent: extent,
                                        source: base,
                                        subjectMask: subjectMask,
                                        opacity: 0.55) else { return image }

        let wash = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.25)).cropped(to: extent)
        return wash.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }
}
