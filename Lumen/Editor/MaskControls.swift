import SwiftUI

/// Parameters for whichever mask the selected layer uses.
struct MaskControls: View {
    @Binding var mask: MaskSpec
    let isWorking: Bool
    let onUndoStroke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(mask.kind.rawValue, systemImage: mask.kind.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Toggle("Invert", isOn: $mask.inverted)
                    .font(.system(size: 11))
                    .toggleStyle(.button)
                    .tint(.yellow)
            }

            switch mask.kind {
            case .whole:
                EmptyView()

            case .radial:
                cgSlider("Size", $mask.radius, 0.02...1.2)
                slider("Feather", $mask.feather, 0.01...1)
                Text("Drag on the photo to move the centre.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

            case .linear:
                doubleSlider("Angle", $mask.angle, 0...360,
                             readout: String(format: "%.0f°", mask.angle))
                slider("Feather", $mask.feather, 0.01...1)
                Text("Drag on the photo to move the transition.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

            case .brush:
                cgSlider("Brush size", $mask.brushRadius, 0.01...0.3)
                slider("Softness", $mask.feather, 0.01...1)
                HStack(spacing: 10) {
                    Toggle(isOn: $mask.erasing) {
                        Label("Erase", systemImage: "eraser")
                    }
                    .toggleStyle(.button)
                    .tint(.yellow)
                    .font(.system(size: 11))

                    Button {
                        onUndoStroke()
                    } label: {
                        Label("Undo stroke", systemImage: "arrow.uturn.backward")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                Text("Paint on the photo to build the mask.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

            case .subject:
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().tint(.yellow)
                        Text("Finding the subject…")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    slider("Edge softness", $mask.feather, 0.01...1)
                    Text("Vision picks out the foreground subject. Invert it to edit the background instead.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }

            case .luminance:
                slider("Range start", $mask.lumaLow, 0...1)
                slider("Range end", $mask.lumaHigh, 0...1)
                slider("Softness", $mask.feather, 0.01...1)
                Text("Targets only the tones inside the range — shadows, midtones or highlights.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // Distinct names, not overloads: an unannotated literal range like `0...1`
    // would otherwise be ambiguous between Float, Double and CGFloat.

    private func slider(_ title: String,
                        _ value: Binding<Float>,
                        _ range: ClosedRange<Float>,
                        readout: String? = nil) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(readout ?? String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Slider(value: value, in: range).tint(.yellow)
        }
    }

    private func cgSlider(_ title: String,
                          _ value: Binding<CGFloat>,
                          _ range: ClosedRange<CGFloat>,
                          readout: String? = nil) -> some View {
        slider(title,
               Binding(get: { Float(value.wrappedValue) },
                       set: { value.wrappedValue = CGFloat($0) }),
               Float(range.lowerBound)...Float(range.upperBound),
               readout: readout)
    }

    private func doubleSlider(_ title: String,
                              _ value: Binding<Double>,
                              _ range: ClosedRange<Double>,
                              readout: String? = nil) -> some View {
        slider(title,
               Binding(get: { Float(value.wrappedValue) },
                       set: { value.wrappedValue = Double($0) }),
               Float(range.lowerBound)...Float(range.upperBound),
               readout: readout)
    }
}
