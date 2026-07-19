/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages a capture session and its inputs and outputs.
*/

import Foundation
@preconcurrency import AVFoundation
import Combine
import Metal
import CoreVideo
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AVFoundation
import CoreImage
import CoreVideo
import Metal

/// An actor that manages the capture pipeline, which includes the capture session, device inputs, and capture outputs.
/// The app defines it as an `actor` type to ensure that all camera operations happen off of the `@MainActor`.
actor CaptureService {
    
    /// A value that indicates whether the capture service is idle or capturing a photo or movie.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    /// A value that indicates the current capture capabilities of the service.
    @Published private(set) var captureCapabilities = CaptureCapabilities.unknown
    /// A value that indicates whether the photo output is ready for a new capture.
    @Published private(set) var captureReadiness: AVCapturePhotoOutput.CaptureReadiness = .sessionNotRunning
    /// A Boolean value that indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    @Published private(set) var isInterrupted = false
    /// A Boolean value that indicates whether the user enables HDR video capture.
    @Published var isHDRVideoEnabled = false
    /// A Boolean value that indicates whether capture controls are in a fullscreen appearance.
    @Published var isShowingFullscreenControls = false
    
    /// A type that connects a preview destination with the capture session.
    nonisolated let previewSource: PreviewSource
    
    // The app's capture session.
    private let captureSession = AVCaptureSession()
    
    // An object that manages the app's photo capture behavior.
    private let photoCapture = PhotoCapture()
    
    // An object that manages the app's video capture behavior.
    private let movieCapture = MovieCapture()
    
    // Add these lines so the app knows about your new system:
    private let videoProcessor = VideoProcessor()
    private var rawFrameCaptureManager: RawFrameCaptureManager?
    
    // An internal collection of output services.
    private var outputServices: [any OutputService] { [photoCapture, movieCapture] }
    
    // The video input for the currently selected device camera.
    private var activeVideoInput: AVCaptureDeviceInput?
    
    // The mode of capture, either photo or video. Defaults to photo.
    private(set) var captureMode = CaptureMode.photo
    
    // An object the service uses to retrieve capture devices.
    private let deviceLookup = DeviceLookup()
    
    // An object that monitors the state of the system-preferred camera.
    private let systemPreferredCamera = SystemPreferredCameraObserver()
    
    // An object that monitors video device rotations.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator!
    private var rotationObservers = [AnyObject]()
    
    // A Boolean value that indicates whether the actor finished its required configuration.
    private var isSetUp = false
    
    // A delegate object that responds to capture control activation and presentation events.
    private var controlsDelegate = CaptureControlsDelegate()
    
    // A map that stores capture controls by device identifier.
    private var controlsMap: [String: [AVCaptureControl]] = [:]
    
    // A serial dispatch queue to use for capture control actions.
    private let sessionQueue = DispatchSerialQueue(label: "com.example.apple-samplecode.AVCam.sessionQueue")
    
    // Sets the session queue as the actor's executor.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }
    
    init() {
        // Create a source object to connect the preview view with the capture session.
        previewSource = DefaultPreviewSource(session: captureSession)
    }
    
    // MARK: - Authorization
    /// A Boolean value that indicates whether a person authorizes this app to use
    /// device cameras and microphones. If they haven't previously authorized the
    /// app, querying this property prompts them for authorization.
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            // Determine whether a person previously authorized camera access.
            var isAuthorized = status == .authorized
            // If the system hasn't determined their authorization status,
            // explicitly prompt them for approval.
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }
    
    // MARK: - Capture session life cycle
    func start(with state: CameraState) async throws {
        // Set initial operating state.
        captureMode = state.captureMode
        isHDRVideoEnabled = state.isVideoHDREnabled
        
        // Exit early if not authorized or the session is already running.
        guard await isAuthorized, !captureSession.isRunning else { return }
        // Configure the session and start it.
        try setUpSession()
        captureSession.startRunning()
    }
    
    // MARK: - Capture setup
    // Performs the initial capture session configuration.
    private func setUpSession() throws {
        // Return early if already set up.
        guard !isSetUp else { return }

        // Observe internal state and notifications.
        observeOutputServices()
        observeNotifications()
        observeCaptureControlsState()
        
        do {
            // Retrieve the default camera and microphone.
            let defaultCamera = try deviceLookup.defaultCamera
            let defaultMic = try deviceLookup.defaultMic

            // Enable using AirPods as a high-quality lapel microphone.
            captureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording = true

            // Add inputs for the default camera and microphone devices.
            activeVideoInput = try addInput(for: defaultCamera)
            try addInput(for: defaultMic)

            // Configure the session preset based on the current capture mode.
            captureSession.sessionPreset = captureMode == .photo ? .photo : .high
            // Add the photo capture output as the default output type.
            try addOutput(photoCapture.output)
            // If the capture mode is set to Video, add a movie capture output.
            if captureMode == .video {
                // Add the movie output as the default output type.
                try addOutput(movieCapture.output)
                setHDRVideoEnabled(isHDRVideoEnabled)
            }
            
            // Configure controls to use with the Camera Control.
            configureControls(for: defaultCamera)
            // Monitor the system-preferred camera state.
            monitorSystemPreferredCamera()
            // Configure a rotation coordinator for the default video device.
            createRotationCoordinator(for: defaultCamera)
            // Observe changes to the default camera's subject area.
            observeSubjectAreaChanges(of: defaultCamera)
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
            
            isSetUp = true
        } catch {
            throw CameraError.setupFailed
        }
    }

    // Adds an input to the capture session to connect the specified capture device.
    @discardableResult
    private func addInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw CameraError.addInputFailed
        }
        return input
    }
    
    // Adds an output to the capture session to connect the specified capture device, if allowed.
    private func addOutput(_ output: AVCaptureOutput) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.addOutputFailed
        }
    }
    
    // The device for the active video input.
    private var currentDevice: AVCaptureDevice {
        guard let device = activeVideoInput?.device else {
            fatalError("No device found for current video input.")
        }
        return device
    }
    
    // MARK: - Capture controls
    
    private func configureControls(for device: AVCaptureDevice) {
        
        // Exit early if the host device doesn't support capture controls.
        guard captureSession.supportsControls else { return }
        
        // Begin configuring the capture session.
        captureSession.beginConfiguration()
        
        // Remove previously configured controls, if any.
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }
        
        // Create controls and add them to the capture session.
        for control in createControls(for: device) {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                logger.info("Unable to add control \(control).")
            }
        }
        
        // Set the controls delegate.
        captureSession.setControlsDelegate(controlsDelegate, queue: sessionQueue)
        
        // Commit the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    func createControls(for device: AVCaptureDevice) -> [AVCaptureControl] {
        // Retrieve the capture controls for this device, if they exist.
        guard let controls = controlsMap[device.uniqueID] else {
            // Define the default controls.
            var controls = [
                AVCaptureSystemZoomSlider(device: device),
                AVCaptureSystemExposureBiasSlider(device: device)
            ]
            // Create a lens position control if the device supports setting a custom position.
            if device.isLockingFocusWithCustomLensPositionSupported {
                // Create a slider to adjust the value from 0 to 1.
                let lensSlider = AVCaptureSlider("Lens Position", symbolName: "circle.dotted.circle", in: 0...1)
                // Perform the slider's action on the session queue.
                lensSlider.setActionQueue(sessionQueue) { lensPosition in
                    do {
                        try device.lockForConfiguration()
                        device.setFocusModeLocked(lensPosition: lensPosition)
                        device.unlockForConfiguration()
                    } catch {
                        logger.info("Unable to change the lens position: \(error)")
                    }
                }
                // Add the slider the controls array.
                controls.append(lensSlider)
            }
            // Store the controls for future use.
            controlsMap[device.uniqueID] = controls
            return controls
        }
        
        // Return the previously created controls.
        return controls
    }
    
    // MARK: - Capture mode selection
    
    /// Changes the mode of capture, which can be `photo` or `video`.
    ///
    /// - Parameter `captureMode`: The capture mode to enable.
    func setCaptureMode(_ captureMode: CaptureMode) throws {
        // Update the internal capture mode value before performing the session configuration.
        self.captureMode = captureMode
        
        // Change the configuration atomically.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Configure the capture session for the selected capture mode.
        switch captureMode {
        case .photo:
            // The app needs to remove the movie capture output to perform Live Photo capture.
            captureSession.sessionPreset = .photo
            captureSession.removeOutput(movieCapture.output)
        case .video:
            captureSession.sessionPreset = .high
            try addOutput(movieCapture.output)
            
            // Integrate your custom pipeline here
            if rawFrameCaptureManager == nil {
                rawFrameCaptureManager = RawFrameCaptureManager(
                    session: captureSession, 
                    videoProcessor: videoProcessor, 
                    targetFrameRate: 30
                )
            }
            
            if isHDRVideoEnabled {
                setHDRVideoEnabled(true)
            }
        }

        // Update the advertised capabilities after reconfiguration.
        updateCaptureCapabilities()
    }
    
    // MARK: - Device selection
    
    /// Changes the capture device that provides video input.
    ///
    /// The app calls this method in response to the user tapping the button in the UI to change cameras.
    /// The implementation switches between the front and back cameras and, in iPadOS,
    /// connected external cameras.
    func selectNextVideoDevice() {
        // The array of available video capture devices.
        let videoDevices = deviceLookup.cameras

        // Find the index of the currently selected video device.
        let selectedIndex = videoDevices.firstIndex(of: currentDevice) ?? 0
        // Get the next index.
        var nextIndex = selectedIndex + 1
        // Wrap around if the next index is invalid.
        if nextIndex == videoDevices.endIndex {
            nextIndex = 0
        }
        
        let nextDevice = videoDevices[nextIndex]
        // Change the session's active capture device.
        changeCaptureDevice(to: nextDevice)
        
        // The app only calls this method in response to the user requesting to switch cameras.
        // Set the new selection as the user's preferred camera.
        AVCaptureDevice.userPreferredCamera = nextDevice
    }
    
    // Changes the device the service uses for video capture.
    private func changeCaptureDevice(to device: AVCaptureDevice) {
        // The service must have a valid video input prior to calling this method.
        guard let currentInput = activeVideoInput else { fatalError() }
        
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Remove the existing video input before attempting to connect a new one.
        captureSession.removeInput(currentInput)
        do {
            // Attempt to connect a new input and device to the capture session.
            activeVideoInput = try addInput(for: device)
            // Configure capture controls for new device selection.
            configureControls(for: device)
            // Configure a new rotation coordinator for the new device.
            createRotationCoordinator(for: device)
            // Register for device observations.
            observeSubjectAreaChanges(of: device)
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
        } catch {
            // Reconnect the existing camera on failure.
            captureSession.addInput(currentInput)
        }
    }
    
    /// Monitors changes to the system's preferred camera selection.
    ///
    /// iPadOS supports external cameras. When someone connects an external camera to their iPad,
    /// they're signaling the intent to use the device. The system responds by updating the
    /// system-preferred camera (SPC) selection to this new device. When this occurs, if the SPC
    /// isn't the currently selected camera, switch to the new device.
    private func monitorSystemPreferredCamera() {
        Task {
            // An object monitors changes to system-preferred camera (SPC) value.
            for await camera in systemPreferredCamera.changes {
                // If the SPC isn't the currently selected camera, attempt to change to that device.
                if let camera, currentDevice != camera {
                    logger.debug("Switching camera selection to the system-preferred camera.")
                    changeCaptureDevice(to: camera)
                }
            }
        }
    }
    
    // MARK: - Rotation handling
    
    /// Create a new rotation coordinator for the specified device and observe its state to monitor rotation changes.
    private func createRotationCoordinator(for device: AVCaptureDevice) {
        // Create a new rotation coordinator for this device.
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
        
        // Set initial rotation state on the preview and output connections.
        updatePreviewRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureRotation(rotationCoordinator.videoRotationAngleForHorizonLevelCapture)
        
        // Cancel previous observations.
        rotationObservers.removeAll()
        
        // Add observers to monitor future changes.
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updatePreviewRotation(angle) }
            }
        )
        
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updateCaptureRotation(angle) }
            }
        )
    }
    
    private func updatePreviewRotation(_ angle: CGFloat) {
        let connection = videoPreviewLayer.connection
        Task { @MainActor in
            // Set initial rotation angle on the video preview.
            connection?.videoRotationAngle = angle
        }
    }
    
    private func updateCaptureRotation(_ angle: CGFloat) {
        // Update the orientation for all output services.
        outputServices.forEach { $0.setVideoRotationAngle(angle) }
    }
    
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // Access the capture session's connected preview layer.
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            fatalError("The app is misconfigured. The capture session should have a connection to a preview layer.")
        }
        return previewLayer
    }
    
    // MARK: - Automatic focus and exposure
    
    /// Performs a one-time automatic focus and expose operation.
    ///
    /// The app calls this method as the result of a person tapping on the preview area.
    func focusAndExpose(at point: CGPoint) {
        // The point this call receives is in view-space coordinates. Convert this point to device coordinates.
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            // Perform a user-initiated focus and expose.
            try focusAndExpose(at: devicePoint, isUserInitiated: true)
        } catch {
            logger.debug("Unable to perform focus and exposure operation. \(error)")
        }
    }
    
    // Observe notifications of type `subjectAreaDidChangeNotification` for the specified device.
    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        // Cancel the previous observation task.
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task {
            // Signal true when this notification occurs.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification, object: device).compactMap({ _ in true }) {
                // Perform a system-initiated focus and expose.
                try? focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        }
    }
    private var subjectAreaChangeTask: Task<Void, Never>?
    
    private func focusAndExpose(at devicePoint: CGPoint, isUserInitiated: Bool) throws {
        // Configure the current device.
        let device = currentDevice
        
        // The following mode and point of interest configuration requires obtaining an exclusive lock on the device.
        try device.lockForConfiguration()
        
        let focusMode = isUserInitiated ? AVCaptureDevice.FocusMode.autoFocus : .continuousAutoFocus
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = focusMode
        }
        
        let exposureMode = isUserInitiated ? AVCaptureDevice.ExposureMode.autoExpose : .continuousAutoExposure
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = exposureMode
        }
        // Enable subject-area change monitoring when performing a user-initiated automatic focus and exposure operation.
        // If this method enables change monitoring, when the device's subject area changes, the app calls this method a
        // second time and resets the device to continuous automatic focus and exposure.
        device.isSubjectAreaChangeMonitoringEnabled = isUserInitiated
        
        // Release the lock.
        device.unlockForConfiguration()
    }
    
    // MARK: - Photo capture
    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        try await photoCapture.capturePhoto(with: features)
    }

    func prepareForCapture(with features: PhotoFeatures) {
        photoCapture.prepareForCapture(with: features)
    }

    /// Switches to a camera or format that supports the requested dimensions if the current configuration doesn't.
    func switchToDeviceSupportingDimensions(_ dimensions: CMVideoDimensions) {
        let currentDimensions = currentDevice.activeFormat.supportedMaxPhotoDimensions
        if currentDimensions.contains(dimensions) { return }

        // Check if a different format on the current device supports the dimensions.
        if let format = currentDevice.formats.first(where: {
            $0.isHighestPhotoQualitySupported && $0.supportedMaxPhotoDimensions.contains(dimensions)
        }) {
            captureSession.beginConfiguration()
            defer { captureSession.commitConfiguration() }
            do {
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                updateCaptureCapabilities()
            } catch {
                logger.error("Unable to switch format: \(error)")
            }
            return
        }

        // Check if another camera supports the dimensions.
        for camera in deviceLookup.allCameras(for: currentDevice.position) where camera != currentDevice {
            let supportsInAnyPhotoFormat = camera.formats.contains { format in
                format.isHighestPhotoQualitySupported && format.supportedMaxPhotoDimensions.contains(dimensions)
            }
            if supportsInAnyPhotoFormat {
                changeCaptureDevice(to: camera)
                return
            }
        }
    }

    func setDeferredProcessingEnabled(_ enabled: Bool) {
        photoCapture.isDeferredProcessingEnabled = enabled
        reconfigurePhotoOutputFeatures()
    }

    func setFastCapturePrioritizationEnabled(_ enabled: Bool) {
        photoCapture.isFastCapturePrioritizationEnabled = enabled
        reconfigurePhotoOutputFeatures()
    }

    func setResponsiveCaptureEnabled(_ enabled: Bool) {
        photoCapture.isResponsiveCaptureEnabled = enabled
        reconfigurePhotoOutputFeatures()
    }

    private func reconfigurePhotoOutputFeatures() {
        let output = photoCapture.output
        output.isResponsiveCaptureEnabled = photoCapture.isResponsiveCaptureEnabled && output.isResponsiveCaptureSupported
        output.isFastCapturePrioritizationEnabled = photoCapture.isFastCapturePrioritizationEnabled && output.isFastCapturePrioritizationSupported
        output.isAutoDeferredPhotoDeliveryEnabled = photoCapture.isDeferredProcessingEnabled && output.isAutoDeferredPhotoDeliverySupported
    }

    // MARK: - Movie capture
    /// Starts recording video. The video records until the user stops recording,
    /// which calls the following `stopRecording()` method.
    func startRecording() {
        if captureMode == .video {
            // Setup the file path for your custom video
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let fileURL = paths[0].appendingPathComponent("output.mov")
            
            // Start the VideoProcessor pipeline
            try? videoProcessor.beginRecording(to: fileURL, width: 1920, height: 1080)
            
            // Start the Raw Frame Capture loop
            rawFrameCaptureManager?.startCapturing()
        } else {
            movieCapture.startRecording()
        }
    }
    
    /// Stops the recording and returns the captured movie.
    func stopRecording() async throws -> Movie {
        if captureMode == .video {
            rawFrameCaptureManager?.stopCapturing()
            
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let fileURL = paths[0].appendingPathComponent("output.mov")
            
            return try await withCheckedThrowingContinuation { continuation in
                videoProcessor.endRecording { url in
                    // Safe check: if url exists, return it; otherwise throw an error
                    if let url = url {
                        continuation.resume(returning: Movie(url: url))
                    } else {
                        // Throwing an error here prevents a crash
                        continuation.resume(throwing: CameraError.setupFailed)
                    }
                }
            }
        } else {
            return try await movieCapture.stopRecording()
        }
    }
    
    /// Sets whether the app captures HDR video.
    func setHDRVideoEnabled(_ isEnabled: Bool) {
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        do {
            // If the current device provides a 10-bit HDR format, enable it for use.
            if isEnabled, let format = currentDevice.activeFormat10BitVariant {
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                isHDRVideoEnabled = true
            } else {
                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
            }
        } catch {
            logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
        }
    }
    
    // MARK: - Internal state management
    /// Updates the state of the actor to ensure its advertised capabilities are accurate.
    ///
    /// When the capture session changes, such as changing modes or input devices, the service
    /// calls this method to update its configuration and capabilities. The app uses this state to
    /// determine which features to enable in the user interface.
    private func updateCaptureCapabilities() {
        // Update the output service configuration.
        outputServices.forEach { $0.updateConfiguration(for: currentDevice) }
        // Set the capture service's capabilities for the selected mode.
        switch captureMode {
        case .photo:
            var capabilities = photoCapture.capabilities
            // Collect dimensions from all cameras and photo formats for the current position.
            var allDimensions = Set<CMVideoDimensions>()
            for camera in deviceLookup.allCameras(for: currentDevice.position) {
                for format in camera.formats where format.isHighestPhotoQualitySupported {
                    allDimensions.formUnion(format.supportedMaxPhotoDimensions)
                }
            }
            let sorted = allDimensions.sorted(by: <)
            var seenLabels = Set<String>()
            let merged = sorted.filter { seenLabels.insert($0.displayString).inserted }
            capabilities = CaptureCapabilities(
                isLivePhotoCaptureSupported: capabilities.isLivePhotoCaptureSupported,
                supportedPhotoDimensions: merged
            )
            captureCapabilities = capabilities
        case .video:
            captureCapabilities = movieCapture.capabilities
        }
    }
    
    /// Merge the `captureActivity` values of the photo and movie capture services,
    /// and assign the value to the actor's property.`
    private func observeOutputServices() {
        Publishers.Merge(photoCapture.$captureActivity, movieCapture.$captureActivity)
            .assign(to: &$captureActivity)
        photoCapture.$captureReadiness
            .assign(to: &$captureReadiness)
    }
    
    /// Observe when capture control enter and exit a fullscreen appearance.
    private func observeCaptureControlsState() {
        controlsDelegate.$isShowingFullscreenControls
            .assign(to: &$isShowingFullscreenControls)
    }
    
    /// Observe capture-related notifications.
    private func observeNotifications() {
        Task {
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                /// Set the `isInterrupted` state as appropriate.
                isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        }
        
        Task {
            // Await notification of the end of an interruption.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                isInterrupted = false
            }
        }
        
        Task {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // If the system resets media services, the capture session stops running.
                if error.code == .mediaServicesWereReset {
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                }
            }
        }
    }
}

class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    
    @Published private(set) var isShowingFullscreenControls = false

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = true
        logger.debug("Capture controls will enter fullscreen appearance.")
    }
    
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = false
        logger.debug("Capture controls will exit fullscreen appearance.")
    }
    
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        logger.debug("Capture controls inactive.")
    }
}
#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Vertex stage
// Fullscreen triangle generated procedurally from vertex_id — no vertex
// buffer needed. Standard trick for post-process / image passes.
// =============================================================================

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut logFilterVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2( 3, -1), float2(-1,  3) };
    const float2 texCoords[3] = { float2( 0,  1), float2( 2,  1), float2( 0, -1) };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// =============================================================================
// Fragment stage
// Reads the Y (luma) and CbCr (chroma) planes of a 10-bit biplanar HLG
// buffer as two textures and writes both planes back out via multiple
// render targets (MRT), so a single pass produces a complete graded frame.
// =============================================================================

struct FragmentOut {
    float  y    [[color(0)]]; // luma plane
    float2 cbcr [[color(1)]]; // chroma plane
};

// Rec.2020/HLG "video range" legal range constants for 10-bit signals
// (luma nominal range 64-940 out of 1023).
constant float kLumaMin = 64.0  / 1023.0;
constant float kLumaMax = 940.0 / 1023.0;

inline float logStyleCurve(float x, float blackLift, float whiteCeiling, float g) {
    float p = pow(clamp(x, 0.0, 1.0), g);
    return blackLift + p * (whiteCeiling - blackLift);
}

/// Reshapes normalized (0-1, full range) luma with a curve that mimics the
/// general SHAPE of a flat log profile: lifted blacks, compressed highlights,
/// boosted mid-tones. These constants are hand-tuned to taste — this is NOT
/// a reverse-engineered reproduction of Sony S-Log or Canon C-Log's actual
/// (proprietary, sensor-specific) transfer functions. Treat it as a starting
/// point to dial in by eye against real footage.
inline float applyLogCurve(float x, float profileType) {
    float blackLift, whiteCeiling, g;
    if (profileType < 0.5) {
        // "sLog"-inspired: deeper lift, flatter mid-tones
        blackLift = 0.06; whiteCeiling = 0.90; g = 0.55;
    } else {
        // "cLog"-inspired: slightly punchier
        blackLift = 0.08; whiteCeiling = 0.88; g = 0.62;
    }
    return logStyleCurve(x, blackLift, whiteCeiling, g);
}

fragment FragmentOut logFilterFragment(VertexOut in [[stage_in]],
                                        texture2d<float, access::sample> yTexture [[texture(0)]],
                                        texture2d<float, access::sample> cbcrTexture [[texture(1)]],
                                        constant float &profileType [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float  yVideo    = yTexture.sample(s, in.texCoord).r;
    float2 cbcrVideo = cbcrTexture.sample(s, in.texCoord).rg;

    // Legal (video) range -> full 0-1 range for the curve math.
    float yFull = clamp((yVideo - kLumaMin) / (kLumaMax - kLumaMin), 0.0, 1.0);

    // This is where the actual "Log math" happens — reshaping the
    // HLG-encoded luma directly rather than linearizing first. That's
    // enough to mimic the look cheaply in real time. If you need
    // colorimetric accuracy instead of a look, invert the HLG OETF to
    // scene-linear before this step and re-apply an OETF afterwards.
    float yGraded = applyLogCurve(yFull, profileType);

    // Back to legal range for the HEVC encoder.
    float yOut = yGraded * (kLumaMax - kLumaMin) + kLumaMin;

    // Mild desaturation so chroma doesn't look artificially punchy sitting
    // under flattened luma — log footage reads as low-contrast AND low-sat.
    float2 chromaOut = (cbcrVideo - 0.5) * 0.85 + 0.5;

    FragmentOut out;
    out.y = yOut;
    out.cbcr = chromaOut;
    return out;
}

// =============================================================================
// RGB-domain variant
// For frames that arrive already debayered (e.g. from a RAW-photo-capture +
// demosaic pipeline) rather than as HLG YCbCr. Shares the vertex stage and
// the applyLogCurve() math above — this is the mathematically correct place
// for a log OETF to happen, since the input here is approximately linear
// scene-referred data, not an already-HLG-encoded signal like the path
// above. Same caveat as before applies to the curve constants: hand-tuned,
// not a byte-for-byte reproduction of a specific vendor's published curve.
// No highlight roll-off here — values above 1.0 hard-clip inside
// logStyleCurve's clamp(). Fine as a starting point; a soft knee is the
// obvious next improvement if you're seeing clipped highlights.
// =============================================================================

fragment half4 logFilterRGBFragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> rgbTexture [[texture(0)]],
                                     constant float &profileType [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 linearColor = rgbTexture.sample(s, in.texCoord);

    float r = applyLogCurve(linearColor.r, profileType);
    float g = applyLogCurve(linearColor.g, profileType);
    float b = applyLogCurve(linearColor.b, profileType);

    return half4(half3(r, g, b), half(linearColor.a));
}

/// Pure Metal + CoreVideo module: takes a 10-bit biplanar (x420) CVPixelBuffer
/// and returns a new one with LogFilter.metal's tone curve applied. Has no
/// knowledge of AVAssetWriter — VideoProcessor is the only thing that wires
/// this into the recording pipeline, so this class could just as easily
/// power a live graded preview instead.
final class MetalLogRenderer {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    /// Second pipeline for debayered RAW frames (single RGBA texture in/out)
    /// rather than the biplanar YCbCr the HLG path uses. Optional: if
    /// logFilterRGBFragment isn't found for some reason, the biplanar path
    /// still works — only renderRGB() is disabled.
    private let rgbPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache!
    private var pixelBufferPool: CVPixelBufferPool?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // These function names must match LogFilter.metal exactly, and that
        // file must be included in the app target's Compile Sources — a
        // common CI gotcha: physically having the file in the folder isn't
        // the same as it being a target member.
        guard
            let library = device.makeDefaultLibrary(),
            let vertexFn = library.makeFunction(name: "logFilterVertex"),
            let fragmentFn = library.makeFunction(name: "logFilterFragment")
        else { return nil }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.colorAttachments[0].pixelFormat = .r16Unorm   // Y plane out
        pipelineDescriptor.colorAttachments[1].pixelFormat = .rg16Unorm  // CbCr plane out

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("MetalLogRenderer: failed to build pipeline state: \(error)")
            return nil
        }

        if let rgbFragmentFn = library.makeFunction(name: "logFilterRGBFragment") {
            let rgbDescriptor = MTLRenderPipelineDescriptor()
            rgbDescriptor.vertexFunction = vertexFn
            rgbDescriptor.fragmentFunction = rgbFragmentFn
            rgbDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            self.rgbPipelineState = try? device.makeRenderPipelineState(descriptor: rgbDescriptor)
        } else {
            self.rgbPipelineState = nil
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.textureCache = cache
    }

    /// Renders `pixelBuffer` through LogFilter.metal and returns a freshly
    /// allocated output buffer in the same 10-bit biplanar format.
    ///
    /// Blocks the calling thread until the GPU finishes — fine at 4K30 on
    /// the A14, but worth revisiting (async completion + a small in-flight
    /// buffer pool) if you push resolution/frame rate higher and start
    /// seeing dropped frames under sustained load.
    func render(pixelBuffer: CVPixelBuffer, profileType: Float) -> CVPixelBuffer? {
        guard let outputBuffer = makeOutputBuffer(matching: pixelBuffer) else { return nil }

        guard
            let yIn = makeTexture(from: pixelBuffer, plane: 0, pixelFormat: .r16Unorm),
            let cbcrIn = makeTexture(from: pixelBuffer, plane: 1, pixelFormat: .rg16Unorm),
            let yOut = makeTexture(from: outputBuffer, plane: 0, pixelFormat: .r16Unorm),
            let cbcrOut = makeTexture(from: outputBuffer, plane: 1, pixelFormat: .rg16Unorm)
        else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = yOut
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[1].texture = cbcrOut
        passDescriptor.colorAttachments[1].loadAction = .dontCare
        passDescriptor.colorAttachments[1].storeAction = .store

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return nil }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yIn, index: 0)
        encoder.setFragmentTexture(cbcrIn, index: 1)
        var profile = profileType
        encoder.setFragmentBytes(&profile, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputBuffer
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            pixelFormat, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func makeOutputBuffer(matching pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if pixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(pixelBuffer),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(pixelBuffer),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pixelBufferPool)
        }
        guard let pool = pixelBufferPool else { return nil }
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
        return outBuffer
    }

    // MARK: - RGB path (debayered RAW frames)

    /// Same idea as render(pixelBuffer:profileType:) but for a single-plane
    /// RGBA input (e.g. a demosaiced RAW frame rendered via CIContext)
    /// instead of biplanar YCbCr. Returns a new 64-bit half-float RGBA
    /// buffer with the log curve applied per-channel.
    func renderRGB(pixelBuffer: CVPixelBuffer, profileType: Float) -> CVPixelBuffer? {
        guard let rgbPipelineState else { return nil }
        guard
            let outputBuffer = makeRGBOutputBuffer(matching: pixelBuffer),
            let inTexture = makeRGBTexture(from: pixelBuffer),
            let outTexture = makeRGBTexture(from: outputBuffer)
        else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = outTexture
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return nil }

        encoder.setRenderPipelineState(rgbPipelineState)
        encoder.setFragmentTexture(inTexture, index: 0)
        var profile = profileType
        encoder.setFragmentBytes(&profile, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outputBuffer
    }

    private func makeRGBTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rgba16Float, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Deliberately a plain CVPixelBufferCreate rather than a pool — the
    /// achievable frame rate from the RAW capture loop is well under video
    /// rate anyway (see RawFrameCaptureManager), so per-frame allocation
    /// overhead isn't the bottleneck here. Worth revisiting if it becomes one.
    private func makeRGBOutputBuffer(matching pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        var outBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault,
                             CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
                             kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &outBuffer)
        return outBuffer
    }
}


/// Replicates Log Cam's core trick: there is no public API for streaming raw
/// Bayer sensor data through AVCaptureVideoDataOutput on any iPhone — that
/// wall is real and this doesn't get around it. What CAN be pulled off is
/// driving AVCapturePhotoOutput's RAW capture (the same pipeline behind DNG
/// stills) in a tight loop instead of the video pipeline, demosaicing each
/// frame yourself, and writing the result out as if it were video.
///
/// Be clear-eyed about what this is: a repurposed photo API standing in for
/// a video one. Expect:
///   - Nowhere near a stable 30fps — each capture has real per-shot overhead
///     that AVCaptureVideoDataOutput's hardware-clocked delivery doesn't.
///   - No continuous autofocus while this runs; photo capture doesn't do that.
///   - Real thermal/pipeline limits on sustained capture — this is exactly
///     the failure mode behind the dropped-recording reports for apps that
///     use this technique. Test sustained runs on your actual device before
///     building anything else on top of this.
///
/// I verified the core APIs used here (AVCapturePhoto.pixelBuffer,
/// CIFilter(cvPixelBuffer:properties:options:), the Bayer pixel format
/// constant) against real developer references while writing this, but this
/// corner of AVFoundation is far less traveled than the video path — budget
/// real device time to work through rough edges I can't catch from here.
final class RawFrameCaptureManager: NSObject {

    /// Which look to apply. .rawHLG doesn't make sense in this pipeline —
    /// there's no HLG signal to bypass, everything here goes through the
    /// RGB grading pass. Default to the flattest look as a sane baseline.
    var currentProfile: LogProfile = .sLog

    private let photoOutput = AVCapturePhotoOutput()
    private let rawFormat: OSType
    private weak var videoProcessor: VideoProcessor?

    private let ciContext: CIContext
    private let metalRenderer: MetalLogRenderer?
    private let processingQueue = DispatchQueue(label: "com.mediosnetwork.rawcapture.processing")

    private var isCapturing = false
    private var frameIndex: Int64 = 0
    private let targetFrameDuration: CMTime

    init?(session: AVCaptureSession, videoProcessor: VideoProcessor, targetFrameRate: Int32 = 30) {
        guard session.canAddOutput(photoOutput) else { return nil }
        session.addOutput(photoOutput)

        // Deliberately plain Bayer RAW, not Apple ProRAW. Multiple developer
        // reports confirm ProRAW still carries Apple's own boost/tone-mapping
        // baked in even with every CIRAWFilterOption disabled — plain Bayer
        // is the closest thing to untouched sensor data a third-party app
        // can pull on iPhone.
        guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else { return nil }
        self.rawFormat = rawFormat

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.ciContext = CIContext(mtlDevice: device)
        self.metalRenderer = MetalLogRenderer(device: device)

        self.videoProcessor = videoProcessor
        self.targetFrameDuration = CMTime(value: 1, timescale: targetFrameRate)

        super.init()
    }

    // MARK: - Loop control

    func startCapturing() {
        guard !isCapturing else { return }
        isCapturing = true
        frameIndex = 0
        captureNextFrame()
    }

    func stopCapturing() {
        isCapturing = false
    }

    private func captureNextFrame() {
        guard isCapturing else { return }
        // RAW-only request: no processedFormat means no companion JPEG/HEIC,
        // which keeps per-shot overhead down.
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.photoQualityPrioritization = .speed
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension RawFrameCaptureManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // This is the backpressure: the next capture only fires once this
        // one is fully off our hands. That serializes the loop and keeps it
        // from overlapping itself, at the cost of the achievable rate being
        // well under 30fps — treat that as a property of the technique, not
        // a bug to chase.
        defer {
            processingQueue.async { [weak self] in
                guard let self, self.isCapturing else { return }
                self.captureNextFrame()
            }
        }

        guard error == nil, let rawPixelBuffer = photo.pixelBuffer else {
            if let error { print("RawFrameCaptureManager: capture failed: \(error)") }
            return
        }
        let metadata = photo.metadata

        processingQueue.async { [weak self] in
            self?.handle(rawPixelBuffer: rawPixelBuffer, metadata: metadata)
        }
    }

    private func handle(rawPixelBuffer: CVPixelBuffer, metadata: [String: Any]) {
        // Demosaic with Apple's own RAW pipeline (CIFilter's raw processing
        // is a well-tested, sanctioned demosaic — reinventing that from
        // scratch buys little), but with every "look" decision it would
        // otherwise bake in turned off. Goal is linear-ish scene data, not
        // Apple's rendering of it.
        let options: [CIRAWFilterOption: Any] = [
            .baselineExposure: 0.0,
            .boostAmount: 0.0,
            .boostShadowAmount: 0.0,
            .disableGamutMap: true
        ]
        guard
            let rawFilter = CIFilter(cvPixelBuffer: rawPixelBuffer, properties: metadata, options: options),
            let demosaiced = rawFilter.outputImage
        else { return }

        guard let rgbaBuffer = makeRGBABuffer(width: Int(demosaiced.extent.width), height: Int(demosaiced.extent.height)) else { return }
        ciContext.render(demosaiced, to: rgbaBuffer)

        guard let graded = metalRenderer?.renderRGB(pixelBuffer: rgbaBuffer, profileType: currentProfile.metalProfileValue) else { return }

        // Synthetic timeline: we're not hardware-clocked here, so we build
        // our own monotonic PTS from a frame counter rather than trying to
        // read a real capture timestamp off a photo request.
        let pts = CMTimeMultiply(targetFrameDuration, multiplier: Int32(frameIndex))
        frameIndex += 1

        videoProcessor?.appendGradedFrame(graded, at: pts)
    }

    private func makeRGBABuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buffer)
        return buffer
    }
}


/// Which "look" a frame should be encoded with.
enum LogProfile: CaseIterable {
    case rawHLG   // straight passthrough of the 10-bit HLG signal
    case sLog     // Metal-graded, Sony S-Log-inspired flat curve
    case cLog     // Metal-graded, Canon C-Log-inspired flat curve

    var displayName: String {
        switch self {
        case .rawHLG: return "Raw HLG"
        case .sLog: return "S-Log Style"
        case .cLog: return "C-Log Style"
        }
    }

    /// Value handed to LogFilter.metal's `profileType` uniform.
    /// Unused for .rawHLG since that path never touches Metal.
    var metalProfileValue: Float {
        switch self {
        case .rawHLG: return -1
        case .sLog: return 0.0
        case .cLog: return 1.0
        }
    }
}

enum VideoProcessorError: Error {
    case cannotAddInput
    case cannotStartWriting
}

/// Consumes CMSampleBuffers from CameraManager and either (a) bypasses them
/// straight into the AVAssetWriter untouched, or (b) runs them through a
/// Metal grading pass first, depending on `currentProfile`.
final class VideoProcessor: NSObject {

    var currentProfile: LogProfile = .rawHLG
    private(set) var isRecording = false

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

    // Serializes all writer state so setup / frame-append / teardown can't
    // race each other across the different queues that call into this class.
    private let writerQueue = DispatchQueue(label: "com.mediosnetwork.videoprocessor.writer")

    private let metalRenderer = MetalLogRenderer()

    // MARK: - Setup / teardown

    /// Configures a 10-bit HEVC (Main10 profile) AVAssetWriter matching the
    /// active capture format's dimensions.
    func beginRecording(to url: URL, width: Int, height: Int,
                        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) throws {
        try writerQueue.sync {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            // Rough heuristic starting point for 10-bit HEVC at ~30fps — tune
            // to taste, or scale it against the format's actual max frame rate.
            let bitRate = Int(Double(width * height) * 0.2 * 30)

            let compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: true,
                // This is the key that actually forces Main10 (10-bit) rather
                // than letting VideoToolbox silently pick an 8-bit profile.
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel
            ]

            let colorProperties: [String: Any] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProperties,
                AVVideoColorPropertiesKey: colorProperties
            ]

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            // The sensor delivers landscape-right buffers (see CameraManager's
            // note on connection rotation). Rotate on playback via the track's
            // display transform rather than physically rotating every frame.
            // Verify on-device — flip the sign to -.pi / 2 if it plays back
            // upside-down/mirrored for your mount orientation.
            vInput.transform = CGAffineTransform(rotationAngle: .pi / 2)

            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: adaptorAttrs)

            guard writer.canAdd(vInput) else { throw VideoProcessorError.cannotAddInput }
            writer.add(vInput)

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100.0,
                AVEncoderBitRateKey: 128_000
            ])
            aInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(aInput) else { throw VideoProcessorError.cannotAddInput }
            writer.add(aInput)

            guard writer.startWriting() else { throw VideoProcessorError.cannotStartWriting }

            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelBufferAdaptor = adaptor
            self.sessionStarted = false
            self.isRecording = true
        }
    }

    func endRecording(completion: @escaping (URL?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.isRecording = false
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                let url = writer.status == .completed ? writer.outputURL : nil
                if writer.status == .failed {
                    print("VideoProcessor: writer failed: \(String(describing: writer.error))")
                }
                self.reset()
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    private func reset() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        sessionStarted = false
    }

    // MARK: - Frame processing

    /// The core branch point: raw HLG bypasses Metal entirely; sLog/cLog run
    /// through LogFilter.metal first.
    func process(sampleBuffer: CMSampleBuffer) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        writerQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, writer.status == .writing else { return }

            if !self.sessionStarted {
                writer.startSession(atSourceTime: pts)
                self.sessionStarted = true
            }

            switch self.currentProfile {
            case .rawHLG:
                // BYPASS: the 10-bit HLG sample buffer goes straight to the
                // writer untouched — no Metal, no recompression of the data.
                guard let input = self.videoInput, input.isReadyForMoreMediaData else { return }
                if !input.append(sampleBuffer) {
                    print("VideoProcessor: raw append failed: \(String(describing: writer.error))")
                }

            case .sLog, .cLog:
                // PIPELINE: reshape the HLG data through Metal first.
                guard
                    let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                    let renderer = self.metalRenderer,
                    let graded = renderer.render(pixelBuffer: pixelBuffer, profileType: self.currentProfile.metalProfileValue),
                    let adaptor = self.pixelBufferAdaptor,
                    let input = self.videoInput,
                    input.isReadyForMoreMediaData
                else { return }
                if !adaptor.append(graded, withPresentationTime: pts) {
                    print("VideoProcessor: graded append failed: \(String(describing: writer.error))")
                }
            }
        }
    }

    func processAudio(sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        writerQueue.async { [weak self] in
            guard let self, self.sessionStarted, let input = self.audioInput, input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    /// For capture paths that never produce a CMSampleBuffer at all — namely
    /// RawFrameCaptureManager's photo-capture loop. Takes an already-graded
    /// pixel buffer plus a self-generated timestamp and appends it directly,
    /// bootstrapping the writer session on the first frame same as process(_:)
    /// does for the camera-driven path.
    func appendGradedFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard isRecording else { return }
        writerQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter, writer.status == .writing else { return }

            if !self.sessionStarted {
                writer.startSession(atSourceTime: time)
                self.sessionStarted = true
            }

            guard
                let adaptor = self.pixelBufferAdaptor,
                let input = self.videoInput,
                input.isReadyForMoreMediaData
            else { return }

            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                print("VideoProcessor: external frame append failed: \(String(describing: writer.error))")
            }
        }
    }
}
