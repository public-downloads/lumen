import CoreGraphics
import Foundation

enum MaskKind: String, CaseIterable, Identifiable, Equatable {
    case whole = "Whole image"
    case radial = "Radial"
    case linear = "Linear"
    case brush = "Brush"
    case subject = "Subject"
    case luminance = "Luminance"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .whole: return "square"
        case .radial: return "circle.dashed"
        case .linear: return "line.diagonal"
        case .brush: return "paintbrush.pointed"
        case .subject: return "person.and.background.dotted"
        case .luminance: return "circle.lefthalf.filled"
        }
    }
}

/// A brush stroke in normalized image space. `y` runs from the top, matching the
/// gesture coordinates the canvas hands us.
struct BrushStroke: Equatable {
    var points: [CGPoint] = []
    var radius: CGFloat = 0.06     // fraction of image width
    var erase: Bool = false
}

struct MaskSpec: Equatable {
    var kind: MaskKind = .whole
    var inverted = false
    var feather: Float = 0.35      // 0…1

    // Radial
    var center = CGPoint(x: 0.5, y: 0.5)
    var radius: CGFloat = 0.35

    // Linear: an angle plus how far along that axis the transition sits.
    var angle: Double = 90         // degrees
    var position: Double = 0.5     // 0…1

    // Brush
    var strokes: [BrushStroke] = []
    var brushRadius: CGFloat = 0.06
    var erasing = false

    // Luminance range
    var lumaLow: Float = 0
    var lumaHigh: Float = 0.5

    /// Cheap identity for the brush raster cache. Grows while a stroke is live,
    /// which is exactly when we want a fresh render.
    var brushCacheKey: String {
        "\(strokes.count)-\(strokes.last?.points.count ?? 0)-\(feather)-\(inverted)"
    }
}

struct AdjustmentLayer: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var adjustments = Adjustments()
    var mask = MaskSpec()
    var opacity: Float = 1
    var isEnabled = true
}

struct Edit: Equatable {
    var global = Adjustments()
    var layers: [AdjustmentLayer] = []
}
