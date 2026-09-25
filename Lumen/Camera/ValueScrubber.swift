import SwiftUI

/// A ticked horizontal scrubber. Works in normalized 0…1 space; callers own the
/// mapping to a real value (see `Scale`) so shutter and ISO can be logarithmic
/// while focus stays linear.
struct ValueScrubber: View {
    let title: String
    let readout: String
    @Binding var normalized: Double

    private let tickCount = 41

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(readout)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.yellow)
            }

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<tickCount, id: \.self) { index in
                            let major = index % 10 == 0
                            Rectangle()
                                .fill(.white.opacity(major ? 0.5 : 0.18))
                                .frame(width: 1, height: major ? 16 : 9)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    Capsule()
                        .fill(.yellow)
                        .frame(width: 2.5, height: 24)
                        .offset(x: normalized * width - 1.25)
                        .shadow(color: .yellow.opacity(0.6), radius: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            normalized = min(max(value.location.x / width, 0), 1)
                        }
                )
            }
            .frame(height: 26)
        }
    }
}

enum Scale {
    static func logNormalize(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard low > 0, high > low, value > 0 else { return 0 }
        return min(max((log(value) - log(low)) / (log(high) - log(low)), 0), 1)
    }

    static func logValue(_ t: Double, _ low: Double, _ high: Double) -> Double {
        guard low > 0, high > low else { return low }
        return low * pow(high / low, min(max(t, 0), 1))
    }

    static func normalize(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard high > low else { return 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    static func value(_ t: Double, _ low: Double, _ high: Double) -> Double {
        low + (high - low) * min(max(t, 0), 1)
    }

    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        if seconds >= 0.4 { return String(format: "%.2f s", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
