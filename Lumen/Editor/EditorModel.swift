import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision

@MainActor
final class EditorModel: ObservableObject {

    @Published private(set) var base: CIImage?          // full resolution
    @Published private(set) var preview: CIImage?       // downscaled for the canvas
    @Published var edit = Edit()
    @Published var selectedLayerID: UUID?
    @Published var showMask = false
    @Published var showOriginal = false
    @Published private(set) var subjectMask: CIImage?
    @Published private(set) var isWorking = false
    @Published var status: String?

    let renderer = MaskRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let previewMaxSide: CGFloat = 2048

    var hasImage: Bool { base != nil }

    var aspectRatio: CGFloat {
        guard let extent = preview?.extent, extent.height > 0 else { return 3.0 / 4.0 }
        return extent.width / extent.height
    }

    var selectedLayer: AdjustmentLayer? {
        guard let id = selectedLayerID else { return nil }
        return edit.layers.first { $0.id == id }
    }

    var selectedLayerBinding: Binding<AdjustmentLayer>? {
        guard let id = selectedLayerID,
              let index = edit.layers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.edit.layers[index] },
            set: { self.edit.layers[index] = $0 }
        )
    }

    /// The image the canvas draws. Cheap to build — Core Image stays lazy until
    /// the Metal view actually renders.
    var displayImage: CIImage? {
        guard let preview else { return nil }
        if showOriginal { return preview }

        let rendered = EditPipeline.render(base: preview,
                                           edit: edit,
                                           renderer: renderer,
                                           subjectMask: subjectMask)
        guard showMask, let layer = selectedLayer else { return rendered }

        return EditPipeline.maskOverlay(over: rendered,
                                        layer: layer,
                                        base: preview,
                                        renderer: renderer,
                                        subjectMask: subjectMask)
    }

    // MARK: - Loading

    func load(_ image: CIImage) {
        renderer.invalidate()
        subjectMask = nil
        edit = Edit()
        selectedLayerID = nil
        showMask = false
        status = nil

        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        base = normalized

        let longest = max(normalized.extent.width, normalized.extent.height)
        let scale = min(1, previewMaxSide / max(longest, 1))
        preview = scale < 1
            ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : normalized
    }

    func load(data: Data) {
        guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
            status = "Could not read that photo"
            return
        }
        load(CIImage(cgImage: cgImage).oriented(CGImagePropertyOrientation(uiImage.imageOrientation)))
    }

    // MARK: - Layers

    func addLayer(kind: MaskKind) {
        var layer = AdjustmentLayer(name: kind == .whole ? "Adjustment" : kind.rawValue)
        layer.mask.kind = kind
        edit.layers.append(layer)
        selectedLayerID = layer.id
        showMask = kind != .whole
        if kind == .subject { requestSubjectMask() }
    }

    func deleteLayer(_ id: UUID) {
        edit.layers.removeAll { $0.id == id }
        if selectedLayerID == id { selectedLayerID = edit.layers.last?.id }
    }

    func appendBrushPoint(_ point: CGPoint, starting: Bool) {
        guard let binding = selectedLayerBinding else { return }
        var layer = binding.wrappedValue
        guard layer.mask.kind == .brush else { return }

        if starting {
            layer.mask.strokes.append(BrushStroke(points: [point],
                                                  radius: layer.mask.brushRadius,
                                                  erase: layer.mask.erasing))
        } else if !layer.mask.strokes.isEmpty {
            layer.mask.strokes[layer.mask.strokes.count - 1].points.append(point)
        }
        binding.wrappedValue = layer
    }

    func undoStroke() {
        guard let binding = selectedLayerBinding else { return }
        var layer = binding.wrappedValue
        guard !layer.mask.strokes.isEmpty else { return }
        layer.mask.strokes.removeLast()
        binding.wrappedValue = layer
    }

    // MARK: - Subject detection

    func requestSubjectMask() {
        guard subjectMask == nil, let source = preview else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let mask = Self.detectSubject(in: source)
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                self.subjectMask = mask
                if mask == nil { self.status = "No subject found in this photo" }
            }
        }
    }

    private nonisolated static func detectSubject(in image: CIImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              let buffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler) else { return nil }

        // Vision hands back a single-channel float buffer; spread it across RGB
        // so CIMaskToAlpha reads it as a proper grayscale mask.
        return CIImage(cvPixelBuffer: buffer).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    // MARK: - Export

    func exportToLibrary() {
        guard let base else { return }
        isWorking = true
        let edit = self.edit
        // A private renderer: the shared one owns a brush cache the UI is still
        // reading on the main actor while this runs.
        let renderer = MaskRenderer()
        // The subject mask was computed on the preview; stretch it to full size.
        let mask = subjectMask?.resized(to: base.extent)
        let context = self.context

        Task.detached(priority: .userInitiated) { [weak self] in
            let rendered = EditPipeline.render(base: base,
                                               edit: edit,
                                               renderer: renderer,
                                               subjectMask: mask)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let data = context.heifRepresentation(of: rendered,
                                                  format: .RGBA8,
                                                  colorSpace: colorSpace,
                                                  options: [:])
                ?? context.jpegRepresentation(
                    of: rendered,
                    colorSpace: colorSpace,
                    options: [CIImageRepresentationOption(
                        rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])

            guard let data else {
                await MainActor.run { self?.isWorking = false; self?.status = "Export failed" }
                return
            }

            do {
                try await PhotoLibrary.save(photo: data)
                await MainActor.run { self?.isWorking = false; self?.status = "Saved to library" }
            } catch {
                await MainActor.run { self?.isWorking = false; self?.status = error.localizedDescription }
            }
        }
    }
}
