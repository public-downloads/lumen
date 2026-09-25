import SwiftUI

/// The slider stack shared by the global edit and every masked layer.
struct AdjustmentControls: View {
    @Binding var adjustments: Adjustments
    @State private var group: SliderGroup = .light

    /// Not named `Group` — that would shadow SwiftUI's own `Group` view.
    private enum SliderGroup: String, CaseIterable, Identifiable {
        case light = "Light"
        case color = "Color"
        case detail = "Detail"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $group) {
                ForEach(SliderGroup.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch group {
            case .light:
                row("Exposure", $adjustments.exposure, -4...4, format: "%+.2f EV")
                row("Contrast", $adjustments.contrast, -1...1)
                row("Highlights", $adjustments.highlights, -1...1)
                row("Shadows", $adjustments.shadows, -1...1)
                row("Whites", $adjustments.whites, -1...1)
                row("Blacks", $adjustments.blacks, -1...1)

            case .color:
                row("Temperature", $adjustments.temperature, -1...1)
                row("Tint", $adjustments.tint, -1...1)
                row("Saturation", $adjustments.saturation, -1...1)
                row("Vibrance", $adjustments.vibrance, -1...1)

            case .detail:
                row("Clarity", $adjustments.clarity, -1...1)
                row("Sharpness", $adjustments.sharpness, 0...1)
                row("Blur", $adjustments.blur, 0...1)
            }

            Button("Reset \(group.rawValue.lowercased())") { reset(group) }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func row(_ title: String,
                     _ value: Binding<Float>,
                     _ range: ClosedRange<Float>,
                     format: String = "%+.2f") -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value.wrappedValue == 0 ? .white.opacity(0.35) : .yellow)
            }
            Slider(value: value, in: range)
                .tint(.yellow)
        }
        // Double-tap a row to zero it.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value.wrappedValue = 0 }
    }

    private func reset(_ group: SliderGroup) {
        switch group {
        case .light:
            adjustments.exposure = 0
            adjustments.contrast = 0
            adjustments.highlights = 0
            adjustments.shadows = 0
            adjustments.whites = 0
            adjustments.blacks = 0
        case .color:
            adjustments.temperature = 0
            adjustments.tint = 0
            adjustments.saturation = 0
            adjustments.vibrance = 0
        case .detail:
            adjustments.clarity = 0
            adjustments.sharpness = 0
            adjustments.blur = 0
        }
    }
}
