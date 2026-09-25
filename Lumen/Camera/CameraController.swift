import AVFoundation
import CoreImage
import Photos
import UIKit

enum ControlMode: String, CaseIterable, Identifiable {
    case auto = "A"
    case manual = "M"
    var id: String { rawValue }
}

struct LensOption: Identifiable, Equatable {
    let id: String                       // AVCaptureDevice.uniqueID
    let label: String
    let position: AVCaptureDevice.Position
}

/// Wraps an `AVCaptureSession` and exposes the manual controls AVFoundation
/// offers: shutter duration, ISO, lens position, white balance gains.
///
/// All session and device mutation happens on `sessionQueue`; every `@Published`
/// write is hopped back to the main queue.
final class CameraController: NSObject, ObservableObject {

    // MARK: - User-settable state

    @Published var exposureMode: ControlMode = .auto { didSet { applyExposure() } }
    @Published var focusMode: ControlMode = .auto { didSet { applyFocus() } }
    @Published var whiteBalanceMode: ControlMode = .auto { didSet { applyWhiteBalance() } }

    @Published var shutterSeconds: Double = 1.0 / 125 { didSet { if exposureMode == .manual { applyExposure() } } }
    @Published var iso: Float = 100 { didSet { if exposureMode == .manual { applyExposure() } } }
    @Published var exposureBias: Float = 0 { didSet { if exposureMode == .auto { applyExposure() } } }
    @Published var lensPosition: Float = 0.5 { didSet { if focusMode == .manual { applyFocus() } } }
    @Published var temperature: Float = 5200 { didSet { if whiteBalanceMode == .manual { applyWhiteBalance() } } }
    @Published var tint: Float = 0 { didSet { if whiteBalanceMode == .manual { applyWhiteBalance() } } }

    @Published var captureRAW = false

    /// Switches the device to whichever active format allows the longest
    /// exposure, keeping resolution within 90% of the best available. Off by
    /// default because it can drop a few megapixels on some devices.
    @Published var preferLongExposure = false { didSet { reconfigureFormat() } }

    // MARK: - Reported / capability state

    @Published private(set) var minShutter: Double = 1.0 / 8000
    @Published private(set) var maxShutter: Double = 1.0 / 3
    @Published private(set) var minISO: Float = 20
    @Published private(set) var maxISO: Float = 800
    @Published private(set) var minBias: Float = -8
    @Published private(set) var maxBias: Float = 8

    @Published private(set) var reportedShutter: Double = 0
    @Published private(set) var reportedISO: Float = 0
    @Published private(set) var reportedLensPosition: Float = 0

    @Published private(set) var lenses: [LensOption] = []
    @Published private(set) var activeLensID: String?
    @Published private(set) var rawAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var accessDenied = false
    @Published private(set) var status: String?
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var lastFullImage: CIImage?

    // MARK: - Internals

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.lumen.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { videoInput?.device }
    private var pollTimer: Timer?
    private var deviceOrientation: UIDeviceOrientation = .portrait

    // capturePhoto() runs on sessionQueue while delegate callbacks arrive on
    // AVFoundation's own queue, so this needs a lock, not just serial access.
    private var inFlight: [Int64: CaptureBundle] = [:]
    private let inFlightLock = NSLock()

    private struct CaptureBundle {
        var processed: Data?
        var raw: Data?
    }

    // MARK: - Lifecycle

    func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.resume()
                if granted {
                    self.configureAndRun()
                } else {
                    self.publish { self.accessDenied = true }
                }
            }
        default:
            publish { self.accessDenied = true }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.publish { self.isRunning = false }
        }
    }

    @objc private func orientationChanged() {
        let o = UIDevice.current.orientation
        if o.isPortrait || o.isLandscape { deviceOrientation = o }
    }

    private func configureAndRun() {
        sessionQueue.async {
            self.discoverLenses()
            self.configureSession(preferredDeviceID: nil)
            if !self.session.isRunning { self.session.startRunning() }
            self.publish {
                self.isRunning = self.session.isRunning
                self.startPolling()
            }
        }
    }

    // MARK: - Session configuration

    private func discoverLenses() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        ]
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .back).devices
        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front).devices

        var options: [LensOption] = back.map {
            LensOption(id: $0.uniqueID, label: Self.label(for: $0), position: .back)
        }
        options += front.map { LensOption(id: $0.uniqueID, label: "Front", position: .front) }
        publish { self.lenses = options }
    }

    private static func label(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5×"
        case .builtInWideAngleCamera: return "1×"
        case .builtInTelephotoCamera: return "Tele"
        default: return "Cam"
        }
    }

    func selectLens(_ option: LensOption) {
        sessionQueue.async { self.configureSession(preferredDeviceID: option.id) }
    }

    private func configureSession(preferredDeviceID: String?) {
        let target: AVCaptureDevice?
        if let id = preferredDeviceID {
            target = AVCaptureDevice(uniqueID: id)
        } else {
            target = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
        }
        guard let device = target else {
            publish { self.status = "No camera available" }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                publish { self.status = "Could not attach camera" }
                return
            }
            session.addInput(input)
            videoInput = input
        } catch {
            session.commitConfiguration()
            publish { self.status = error.localizedDescription }
            return
        }

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }

        applyBestFormat(to: device)

        if let dims = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dims
        }

        session.commitConfiguration()

        readCapabilities(from: device)
        applyExposure()
        applyFocus()
        applyWhiteBalance()

        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        publish {
            self.activeLensID = device.uniqueID
            self.rawAvailable = !rawTypes.isEmpty
        }
    }

    private func reconfigureFormat() {
        sessionQueue.async {
            guard let device = self.device else { return }
            self.session.beginConfiguration()
            self.applyBestFormat(to: device)
            if let dims = device.activeFormat.supportedMaxPhotoDimensions.last {
                self.photoOutput.maxPhotoDimensions = dims
            }
            self.session.commitConfiguration()
            self.readCapabilities(from: device)
            self.applyExposure()
        }
    }

    /// Picks the active format. Normally that is whatever `.photo` selected; with
    /// `preferLongExposure` we hunt for the format with the longest
    /// `maxExposureDuration` that still shoots near-full resolution.
    private func applyBestFormat(to device: AVCaptureDevice) {
        guard preferLongExposure else { return }

        let bestWidth = device.formats
            .compactMap { $0.supportedMaxPhotoDimensions.last?.width }
            .max() ?? 0
        guard bestWidth > 0 else { return }
        let threshold = Int32(Double(bestWidth) * 0.9)

        let candidate = device.formats
            .filter { ($0.supportedMaxPhotoDimensions.last?.width ?? 0) >= threshold }
            .max { $0.maxExposureDuration.seconds < $1.maxExposureDuration.seconds }

        guard let candidate,
              candidate.maxExposureDuration.seconds > device.activeFormat.maxExposureDuration.seconds
        else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = candidate
        } catch {
            publish { self.status = "Could not switch format: \(error.localizedDescription)" }
        }
    }

    private func readCapabilities(from device: AVCaptureDevice) {
        let format = device.activeFormat
        let loShutter = max(format.minExposureDuration.seconds, 1.0 / 32000)
        let hiShutter = max(format.maxExposureDuration.seconds, loShutter * 2)
        let loISO = format.minISO
        let hiISO = format.maxISO
        let loBias = device.minExposureTargetBias
        let hiBias = device.maxExposureTargetBias

        publish {
            self.minShutter = loShutter
            self.maxShutter = hiShutter
            self.minISO = loISO
            self.maxISO = hiISO
            self.minBias = loBias
            self.maxBias = hiBias
            self.shutterSeconds = min(max(self.shutterSeconds, loShutter), hiShutter)
            self.iso = min(max(self.iso, loISO), hiISO)
        }
    }

    // MARK: - Live readout
    //
    // AVCaptureDevice is KVO-compliant for these, but polling is simpler and
    // cannot crash on a keypath typo — worth it for a value we only show.

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let device = self.device else { return }
            let duration = device.exposureDuration.seconds
            let currentISO = device.iso
            let lens = device.lensPosition
            DispatchQueue.main.async {
                if duration.isFinite { self.reportedShutter = duration }
                self.reportedISO = currentISO
                self.reportedLensPosition = lens
            }
        }
    }

    // MARK: - Manual controls

    private func applyExposure() {
        let mode = exposureMode
        let seconds = shutterSeconds
        let sensitivity = iso
        let bias = exposureBias

        withDevice { device in
            switch mode {
            case .auto:
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)

            case .manual:
                guard device.isExposureModeSupported(.custom) else { return }
                let format = device.activeFormat
                let lo = format.minExposureDuration.seconds
                let hi = format.maxExposureDuration.seconds
                let safe = min(max(seconds, lo), hi)
                let duration = CMTime(seconds: safe, preferredTimescale: 1_000_000_000)
                let safeISO = min(max(sensitivity, format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: duration, iso: safeISO, completionHandler: nil)
            }
        }
    }

    private func applyFocus() {
        let mode = focusMode
        let position = lensPosition

        withDevice { device in
            switch mode {
            case .auto:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            case .manual:
                guard device.isFocusModeSupported(.locked) else { return }
                device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance() {
        let mode = whiteBalanceMode
        let kelvin = temperature
        let tintValue = tint

        withDevice { device in
            switch mode {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case .manual:
                guard device.isWhiteBalanceModeSupported(.locked) else { return }
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: min(max(kelvin, 2000), 10_000),
                    tint: min(max(tintValue, -150), 150))
                var gains = device.deviceWhiteBalanceGains(for: values)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    /// Tap-to-focus / tap-to-meter. `point` is in device coordinates (0–1).
    func focusAndExpose(at point: CGPoint) {
        let wantsAutoFocus = focusMode == .auto
        let wantsAutoExposure = exposureMode == .auto

        withDevice { device in
            if wantsAutoFocus, device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if wantsAutoExposure, device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                body(device)
            } catch {
                self.publish { self.status = error.localizedDescription }
            }
        }
    }

    // MARK: - Capture

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        let wantsRAW = captureRAW
        let manualExposure = exposureMode == .manual
        let angle = Self.rotationAngle(for: deviceOrientation)

        sessionQueue.async {
            let settings: AVCapturePhotoSettings

            if wantsRAW, let rawType = self.preferredRawFormat() {
                let processedCodec: AVVideoCodecType =
                    self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawType,
                    processedFormat: [AVVideoCodecKey: processedCodec])
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }

            settings.flashMode = .off
            // Assigning zeroed dimensions throws; only forward a real value.
            let dimensions = self.photoOutput.maxPhotoDimensions
            if dimensions.width > 0, dimensions.height > 0 {
                settings.maxPhotoDimensions = dimensions
            }
            // In manual mode, .speed keeps the single manual-exposure frame intact.
            // Deep Fusion / Smart HDR would otherwise blend brackets and quietly
            // undo the shutter and ISO you dialled in.
            settings.photoQualityPrioritization = manualExposure ? .speed : .balanced

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            self.inFlightLock.lock()
            self.inFlight[settings.uniqueID] = CaptureBundle()
            self.inFlightLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func preferredRawFormat() -> OSType? {
        let available = photoOutput.availableRawPhotoPixelFormatTypes
        // ProRAW carries Apple's tone mapping and edits far better than Bayer.
        if let proRAW = available.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        return available.first
    }

    /// If landscape captures come out rotated 180°, swap these two values.
    private static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return 90
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            publish { self.status = error.localizedDescription }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let id = photo.resolvedSettings.uniqueID

        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        var bundle = inFlight[id] ?? CaptureBundle()
        if photo.isRawPhoto { bundle.raw = data } else { bundle.processed = data }
        inFlight[id] = bundle
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        inFlightLock.lock()
        let bundle = inFlight.removeValue(forKey: resolvedSettings.uniqueID)
        inFlightLock.unlock()

        publish { self.isCapturing = false }

        guard let bundle, let viewable = bundle.processed ?? bundle.raw else {
            if let error { publish { self.status = error.localizedDescription } }
            return
        }

        // Thumbnail + editor handoff from the processed (displayable) file.
        if let uiImage = UIImage(data: viewable) {
            let thumb = uiImage.downscaled(toLongestSide: 300)
            let full = uiImage.cgImage.map {
                CIImage(cgImage: $0).oriented(CGImagePropertyOrientation(uiImage.imageOrientation))
            }
            publish {
                self.lastThumbnail = thumb
                self.lastFullImage = full
            }
        }

        Task {
            do {
                try await PhotoLibrary.save(photo: viewable,
                                            alternateRAW: bundle.processed == nil ? nil : bundle.raw)
                self.publish { self.status = bundle.raw == nil ? "Saved" : "Saved + RAW" }
            } catch {
                self.publish { self.status = "Save failed: \(error.localizedDescription)" }
            }
        }
    }
}
