import AVFoundation
import SwiftUI

struct CameraView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var camera = CameraController()
    @State private var activeControl: Control = .shutter
    @State private var focusIndicator: CGPoint?

    enum Control: String, CaseIterable, Identifiable {
        case shutter = "SHUTTER"
        case iso = "ISO"
        case focus = "FOCUS"
        case wb = "WB"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.accessDenied {
                deniedView
            } else {
                VStack(spacing: 0) {
                    topBar
                    preview
                    controls
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: camera.session) { devicePoint, viewPoint in
                    camera.focusAndExpose(at: devicePoint)
                    withAnimation(.easeOut(duration: 0.15)) { focusIndicator = viewPoint }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation { focusIndicator = nil }
                    }
                }

                if let point = focusIndicator {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 1)
                        .frame(width: 70, height: 70)
                        .position(point)
                        .transition(.opacity)
                }

                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(camera.lenses) { lens in
                            Button {
                                camera.selectLens(lens)
                            } label: {
                                Text(lens.label)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 44, height: 32)
                                    .background(
                                        Capsule().fill(
                                            camera.activeLensID == lens.id
                                            ? Color.yellow.opacity(0.9)
                                            : Color.black.opacity(0.45)))
                                    .foregroundStyle(camera.activeLensID == lens.id ? .black : .white)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            toggleChip("RAW", isOn: camera.captureRAW, enabled: camera.rawAvailable) {
                camera.captureRAW.toggle()
            }
            toggleChip("LONG", isOn: camera.preferLongExposure, enabled: true) {
                camera.preferLongExposure.toggle()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(Scale.shutterLabel(camera.reportedShutter))
                Text("ISO \(Int(camera.reportedISO))")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleChip(_ label: String, isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isOn ? Color.yellow : Color.white.opacity(0.12)))
                .foregroundStyle(isOn ? .black : .white)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Control.allCases) { control in
                    Button {
                        activeControl = control
                    } label: {
                        VStack(spacing: 2) {
                            Text(control.rawValue)
                                .font(.system(size: 10, weight: .bold))
                            Text(modeLabel(for: control))
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(isManual(control) ? .yellow : .white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(activeControl == control ? Color.white.opacity(0.16) : .clear))
                        .foregroundStyle(.white)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.35).onEnded { _ in toggleMode(control) }
                    )
                }
            }
            .padding(.horizontal, 14)

            scrubber
                .padding(.horizontal, 22)

            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))

            shutterRow
        }
        .padding(.bottom, 6)
        .frame(maxHeight: .infinity)
    }

    private var hint: String {
        if let status = camera.status { return status }
        return "Long-press a control to switch between auto and manual"
    }

    @ViewBuilder
    private var scrubber: some View {
        switch activeControl {
        case .shutter:
            ValueScrubber(
                title: camera.exposureMode == .manual ? "SHUTTER" : "EXPOSURE COMP",
                readout: camera.exposureMode == .manual
                    ? Scale.shutterLabel(camera.shutterSeconds)
                    : String(format: "%+.1f EV", camera.exposureBias),
                normalized: camera.exposureMode == .manual
                    ? Binding(
                        get: { Scale.logNormalize(camera.shutterSeconds, camera.minShutter, camera.maxShutter) },
                        set: { camera.shutterSeconds = Scale.logValue($0, camera.minShutter, camera.maxShutter) })
                    : Binding(
                        get: { Scale.normalize(Double(camera.exposureBias), Double(camera.minBias), Double(camera.maxBias)) },
                        set: { camera.exposureBias = Float(Scale.value($0, Double(camera.minBias), Double(camera.maxBias))) })
            )

        case .iso:
            ValueScrubber(
                title: "ISO",
                readout: "\(Int(camera.exposureMode == .manual ? camera.iso : camera.reportedISO))",
                normalized: Binding(
                    get: { Scale.logNormalize(Double(camera.iso), Double(camera.minISO), Double(camera.maxISO)) },
                    set: { camera.iso = Float(Scale.logValue($0, Double(camera.minISO), Double(camera.maxISO))) })
            )
            .disabled(camera.exposureMode == .auto)
            .opacity(camera.exposureMode == .auto ? 0.35 : 1)

        case .focus:
            ValueScrubber(
                title: "FOCUS",
                readout: camera.focusMode == .manual
                    ? String(format: "%.2f", camera.lensPosition)
                    : String(format: "auto %.2f", camera.reportedLensPosition),
                normalized: Binding(
                    get: { Double(camera.lensPosition) },
                    set: { camera.lensPosition = Float($0) })
            )
            .disabled(camera.focusMode == .auto)
            .opacity(camera.focusMode == .auto ? 0.35 : 1)

        case .wb:
            VStack(spacing: 10) {
                ValueScrubber(
                    title: "TEMPERATURE",
                    readout: "\(Int(camera.temperature)) K",
                    normalized: Binding(
                        get: { Scale.normalize(Double(camera.temperature), 2000, 10_000) },
                        set: { camera.temperature = Float(Scale.value($0, 2000, 10_000)) })
                )
                ValueScrubber(
                    title: "TINT",
                    readout: String(format: "%+.0f", camera.tint),
                    normalized: Binding(
                        get: { Scale.normalize(Double(camera.tint), -150, 150) },
                        set: { camera.tint = Float(Scale.value($0, -150, 150)) })
                )
            }
            .disabled(camera.whiteBalanceMode == .auto)
            .opacity(camera.whiteBalanceMode == .auto ? 0.35 : 1)
        }
    }

    private var shutterRow: some View {
        HStack {
            Button {
                if let image = camera.lastFullImage { app.openInEditor(image) }
            } label: {
                Group {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25)))
            }
            .disabled(camera.lastFullImage == nil)

            Spacer()

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 72, height: 72)
                    Circle()
                        .fill(camera.isCapturing ? Color.white.opacity(0.4) : .white)
                        .frame(width: 60, height: 60)
                }
            }
            .disabled(!camera.isRunning)

            Spacer()

            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Mode helpers

    private func isManual(_ control: Control) -> Bool {
        switch control {
        case .shutter, .iso: return camera.exposureMode == .manual
        case .focus: return camera.focusMode == .manual
        case .wb: return camera.whiteBalanceMode == .manual
        }
    }

    private func modeLabel(for control: Control) -> String {
        isManual(control) ? "MAN" : "AUTO"
    }

    private func toggleMode(_ control: Control) {
        switch control {
        case .shutter, .iso:
            camera.exposureMode = camera.exposureMode == .auto ? .manual : .auto
            if camera.exposureMode == .manual {
                // Seed manual values from what auto had settled on.
                if camera.reportedShutter > 0 { camera.shutterSeconds = camera.reportedShutter }
                if camera.reportedISO > 0 { camera.iso = camera.reportedISO }
            }
        case .focus:
            camera.focusMode = camera.focusMode == .auto ? .manual : .auto
            if camera.focusMode == .manual { camera.lensPosition = camera.reportedLensPosition }
        case .wb:
            camera.whiteBalanceMode = camera.whiteBalanceMode == .auto ? .manual : .auto
        }
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown").font(.largeTitle)
            Text("Camera access is off")
                .font(.headline)
            Text("Enable it in Settings › Lumen › Camera.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
