import CoreImage
import PhotosUI
import SwiftUI

@MainActor
struct EditorView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var isStroking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar

                if model.hasImage {
                    canvas
                    Divider().overlay(Color.white.opacity(0.1))
                    layerStrip
                    controlPanel
                } else {
                    emptyState
                }
            }
        }
        .onAppear { consumeHandoff() }
        .onChange(of: app.pendingImage) { _, _ in consumeHandoff() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.load(data: data)
                }
            }
        }
    }

    private func consumeHandoff() {
        if let image = app.consumePendingImage() { model.load(image) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 18) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle.angled")
            }

            Spacer()

            if model.hasImage {
                Button {
                    model.showMask.toggle()
                } label: {
                    Image(systemName: model.showMask ? "eye.trianglebadge.exclamationmark.fill" : "eye.trianglebadge.exclamationmark")
                }
                .foregroundStyle(model.showMask ? .yellow : .white)
                .disabled(model.selectedLayer == nil)
                .opacity(model.selectedLayer == nil ? 0.3 : 1)

                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                    .foregroundStyle(model.showOriginal ? .yellow : .white)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in model.showOriginal = true }
                            .onEnded { _ in model.showOriginal = false }
                    )

                Button {
                    model.exportToLibrary()
                } label: {
                    if model.isWorking {
                        ProgressView().tint(.yellow)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(model.isWorking)
            }
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if let status = model.status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            MetalCanvasView(image: model.displayImage)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(canvasGesture(size: geo.size))
        }
        .aspectRatio(model.aspectRatio, contentMode: .fit)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }

    private func canvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let binding = model.selectedLayerBinding else { return }
                let point = value.location
                let w = max(size.width, 1)
                let h = max(size.height, 1)

                switch binding.wrappedValue.mask.kind {
                case .brush:
                    let normalized = CGPoint(x: point.x / w, y: point.y / h)
                    model.appendBrushPoint(normalized, starting: !isStroking)
                    isStroking = true

                case .radial:
                    binding.wrappedValue.mask.center = CGPoint(
                        x: min(max(point.x / w, 0), 1),
                        y: min(max(point.y / h, 0), 1))

                case .linear:
                    // Project the touch onto the mask axis, in Core Image
                    // coordinates (origin bottom-left) to match MaskRenderer.
                    let radians = binding.wrappedValue.mask.angle * .pi / 180
                    let dx = point.x - w / 2
                    let dy = (h - point.y) - h / 2
                    let projection = (dx * cos(radians) + dy * sin(radians)) / hypot(w, h)
                    binding.wrappedValue.mask.position = min(max(0.5 + projection, 0), 1)

                default:
                    break
                }
            }
            .onEnded { _ in isStroking = false }
    }

    // MARK: - Layers

    private var layerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Global", symbol: "globe", selected: model.selectedLayerID == nil) {
                    model.selectedLayerID = nil
                    model.showMask = false
                }

                ForEach(model.edit.layers) { layer in
                    chip(title: layer.name,
                         symbol: layer.mask.kind.symbol,
                         selected: model.selectedLayerID == layer.id) {
                        if model.selectedLayerID == layer.id {
                            model.showMask.toggle()
                        } else {
                            model.selectedLayerID = layer.id
                            if layer.mask.kind == .subject { model.requestSubjectMask() }
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { model.deleteLayer(layer.id) }
                    }
                    .opacity(layer.isEnabled ? 1 : 0.4)
                }

                Menu {
                    ForEach(MaskKind.allCases) { kind in
                        Button {
                            model.addLayer(kind: kind)
                        } label: {
                            Label(kind.rawValue, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.yellow : Color.white.opacity(0.12)))
            .foregroundStyle(selected ? .black : .white)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let binding = model.selectedLayerBinding {
                    if binding.wrappedValue.mask.kind != .whole {
                        MaskControls(mask: binding.mask, isWorking: model.isWorking) {
                            model.undoStroke()
                        }
                        Divider().overlay(Color.white.opacity(0.1))
                    }

                    HStack {
                        Text("LAYER STRENGTH")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: binding.opacity, in: 0...1)
                        Toggle("", isOn: binding.isEnabled).labelsHidden()
                    }

                    AdjustmentControls(adjustments: binding.adjustments)
                } else {
                    AdjustmentControls(adjustments: $model.edit.global)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(height: 250)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.stack").font(.system(size: 42)).foregroundStyle(.white.opacity(0.3))
            Text("Open a photo to edit")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("Choose from Library")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.yellow))
                    .foregroundStyle(.black)
            }
            Text("Or shoot one in the Camera tab and tap the thumbnail.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
    }
}
