import AVFoundation
import CoreMedia

/// Owns the AVCaptureSession and routes raw frames to the VideoProcessor.
/// Targets 10-bit HLG (Hybrid Log-Gamma) capture — the highest-quality HDR
/// pipeline the iPhone 12 Pro Max exposes. Apple Log/ProRes requires the
/// A17 Pro-generation sensor (iPhone 15 Pro and later), so HLG + a Metal
/// grading pass is the correct target here, not a workaround.
///
/// Confirmed: the 12 Pro Max shoots Dolby Vision HDR up to 4K/60fps, 10-bit —
/// so the format selector below is written to find the best HLG format
/// rather than hardcoding a resolution/frame rate ceiling.
final class CameraManager: NSObject, ObservableObject {

    @Published private(set) var isSessionRunning = false
    @Published private(set) var permissionGranted = false
    @Published var currentProfile: LogProfile = .rawHLG {
        didSet { videoProcessor.currentProfile = currentProfile }
    }

    let session = AVCaptureSession()
    let videoProcessor = VideoProcessor()

    private let sessionQueue = DispatchQueue(label: "com.mediosnetwork.cameramanager.session")
    private let dataOutputQueue = DispatchQueue(label: "com.mediosnetwork.cameramanager.dataoutput")

    private var videoDevice: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // MARK: - Permissions

    func requestPermissionsAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async {
                    self?.permissionGranted = videoGranted && audioGranted
                }
                guard videoGranted && audioGranted else { return }
                self?.sessionQueue.async { self?.configureSession() }
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // .inputPriority hands control of resolution/format to `activeFormat`
        // instead of a fixed AVCaptureSession.Preset. This is required to opt
        // into the 10-bit HLG formats — presets like .hd4K3840x2160 will only
        // ever hand you 8-bit 420v/BGRA.
        session.sessionPreset = .inputPriority

        guard let device = bestBackCamera() else {
            print("CameraManager: no back camera available.")
            return
        }
        guard let format = bestHLGFormat(for: device) else {
            print("CameraManager: no 10-bit HLG format found on this device/OS. There's no 8-bit fallback wired up here — add one if you need to support hardware that predates this pipeline.")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeColorSpace = .HLG_BT2020
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: could not lock device for configuration: \(error)")
            return
        }
        self.videoDevice = device

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else { return }
            session.addInput(videoInput)
        } catch {
            print("CameraManager: could not create video input: \(error)")
            return
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        // AVCaptureVideoDataOutput negotiates its own `videoSettings` — it does
        // NOT automatically inherit the device's activeFormat pixel format, so
        // this has to be requested explicitly.
        guard videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) else {
            print("CameraManager: video data output can't deliver 10-bit biplanar buffers on this device.")
            return
        }
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // Deliberately NOT touching connection.videoRotationAngle here.
        // Rotating at the data-output connection physically rotates the
        // delivered CVPixelBuffers (width/height swap), which would desync
        // the dimensions CameraManager reads from `activeFormat` when it
        // configures the AVAssetWriter below. Portrait orientation is instead
        // applied as a display transform on the AVAssetWriterInput — see
        // VideoProcessor.beginRecording().

        audioOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }
    }

    private func bestBackCamera() -> AVCaptureDevice? {
        let candidateTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera
        ]
        for type in candidateTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    /// Finds the highest-resolution format that both (a) delivers the 10-bit
    /// biplanar pixel format and (b) advertises HLG_BT2020 color space support,
    /// preferring higher max frame rate as a tiebreaker.
    private func bestHLGFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is10BitBiPlanar = subType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            let supportsHLG = format.supportedColorSpaces.contains(.HLG_BT2020)
            return is10BitBiPlanar && supportsHLG
        }

        return candidates.max { a, b in
            let dimsA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let dimsB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pixelsA = Int(dimsA.width) * Int(dimsA.height)
            let pixelsB = Int(dimsB.width) * Int(dimsB.height)
            if pixelsA != pixelsB { return pixelsA < pixelsB }
            let fpsA = a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let fpsB = b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return fpsA < fpsB
        }
    }

    // MARK: - Session lifecycle

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard let device = videoDevice else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        do {
            try videoProcessor.beginRecording(to: url, width: Int(dims.width), height: Int(dims.height))
        } catch {
            print("CameraManager: failed to start recording: \(error)")
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        videoProcessor.endRecording(completion: completion)
    }
}

// MARK: - Sample buffer routing

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        switch output {
        case is AVCaptureVideoDataOutput:
            videoProcessor.process(sampleBuffer: sampleBuffer)
        case is AVCaptureAudioDataOutput:
            videoProcessor.processAudio(sampleBuffer: sampleBuffer)
        default:
            break
        }
    }
}
