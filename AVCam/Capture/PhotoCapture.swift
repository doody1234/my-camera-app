/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages a photo capture output to take photographs.
*/

import AVFoundation
import CoreImage

enum PhotoCaptureError: Error {
    case noPhotoData
}

/// An object that manages a photo capture output to perform take photographs.
final class PhotoCapture: OutputService {

    /// A value that indicates the current state of photo capture.
    @Published private(set) var captureActivity: CaptureActivity = .idle

    /// A value that indicates whether the photo output is ready for a new capture.
    @Published private(set) var captureReadiness: AVCapturePhotoOutput.CaptureReadiness = .sessionNotRunning

    /// The capture output type for this service.
    let output = AVCapturePhotoOutput()

    // An internal alias for the output.
    private var photoOutput: AVCapturePhotoOutput { output }

    // The readiness coordinator for the photo output.
    private var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var readinessDelegate: ReadinessDelegate?

    // The current capabilities available.
    private(set) var capabilities: CaptureCapabilities = .unknown

    // A count of Live Photo captures currently in progress.
    private var livePhotoCount = 0

    // MARK: - Capture a photo.

    /// The app calls this method when the user taps the photo capture button.
    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        // Wrap the delegate-based capture API in a continuation to use it in an async context.
        try await withCheckedThrowingContinuation { continuation in

            // Create a settings object to configure the photo capture.
            let photoSettings = createPhotoSettings(with: features)

            // Track the request in the readiness coordinator before capturing.
            readinessCoordinator?.startTrackingCaptureRequest(using: photoSettings)

            let delegate = PhotoCaptureDelegate(continuation: continuation)
            monitorProgress(of: delegate)

            // Capture a new photo with the specified settings.
            photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
        }
    }
    
    // MARK: - Create a photo settings object.

    /// Prepares the photo output for capture with the specified features.
    func prepareForCapture(with features: PhotoFeatures) {
        let photoSettings = createPhotoSettings(with: features)
        photoOutput.setPreparedPhotoSettingsArray([photoSettings]) { prepared, error in
            if let error {
                logger.debug("Failed to prepare photo settings: \(error)")
            }
        }
    }

    // Create a photo settings object with the features a person enables in the UI.
    private func createPhotoSettings(with features: PhotoFeatures) -> AVCapturePhotoSettings {
        // Create a new settings object to configure the photo capture.
        var photoSettings = AVCapturePhotoSettings()
        
        // Capture photos in HEIF format when the device supports it.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        /// Set the format of the preview image to capture. The `photoSettings` object returns the available
        /// preview format types in order of compatibility with the primary image.
        if let previewPhotoPixelFormatType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
        }
        
        // Use the requested dimensions if supported by the current active format, otherwise fall back to the output's max.
        if currentSupportedDimensions.contains(features.maxPhotoDimensions) {
            photoSettings.maxPhotoDimensions = features.maxPhotoDimensions
        } else {
            photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }
        
        // Set the movie URL if the photo output supports Live Photo capture.
        photoSettings.livePhotoMovieFileURL = features.isLivePhotoEnabled ? URL.movieFileURL : nil
        
        // Set the priority of speed versus quality during this capture.
        if let prioritization = AVCapturePhotoOutput.QualityPrioritization(rawValue: features.qualityPrioritization.rawValue) {
            photoSettings.photoQualityPrioritization = prioritization
        }
        
        return photoSettings
    }
    
    /// Monitors the progress of a photo capture delegate.
    ///
    /// The `PhotoCaptureDelegate` produces an asynchronous stream of values that indicate its current activity.
    /// The app propagates the activity values up to the view tier so the UI can update accordingly.
    private func monitorProgress(of delegate: PhotoCaptureDelegate, isolation: isolated (any Actor)? = #isolation) {
        Task {
            _ = isolation
            var isLivePhoto = false
            // Asynchronously monitor the activity of the delegate while the system performs capture.
            for await activity in delegate.activityStream {
                var currentActivity = activity
                /// More than one activity value for the delegate may report that `isLivePhoto` is `true`.
                /// Only increment/decrement the count when the value changes from its previous state.
                if activity.isLivePhoto != isLivePhoto {
                    isLivePhoto = activity.isLivePhoto
                    // Increment or decrement as appropriate.
                    livePhotoCount += isLivePhoto ? 1 : -1
                    if livePhotoCount > 1 {
                        /// Set `isLivePhoto` to `true` when there are concurrent Live Photos in progress.
                        /// This prevents the "Live" badge in the UI from flickering.
                        currentActivity = .photoCapture(willCapture: activity.willCapture, isLivePhoto: true)
                    }
                }
                captureActivity = currentActivity
            }
        }
    }
    
    // The current device's supported dimensions for validation at capture time.
    private var currentSupportedDimensions: [CMVideoDimensions] = []

    var isDeferredProcessingEnabled = true
    var isFastCapturePrioritizationEnabled = true
    var isResponsiveCaptureEnabled = true

    // MARK: - Update the photo output configuration

    /// Reconfigures the photo output and updates the output service's capabilities accordingly.
    ///
    /// The `CaptureService` calls this method whenever you change cameras.
    ///
    func updateConfiguration(for device: AVCaptureDevice) {
        // Enable all supported features.
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        currentSupportedDimensions = supportedDimensions
        photoOutput.maxPhotoDimensions = supportedDimensions.last ?? .zero
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isResponsiveCaptureEnabled = isResponsiveCaptureEnabled && photoOutput.isResponsiveCaptureSupported
        photoOutput.isFastCapturePrioritizationEnabled = isFastCapturePrioritizationEnabled && photoOutput.isFastCapturePrioritizationSupported
        photoOutput.isAutoDeferredPhotoDeliveryEnabled = isDeferredProcessingEnabled && photoOutput.isAutoDeferredPhotoDeliverySupported
        configureReadinessCoordinator()
        updateCapabilities(for: device)
    }
    
    private func updateCapabilities(for device: AVCaptureDevice) {
        capabilities = CaptureCapabilities(
            isLivePhotoCaptureSupported: photoOutput.isLivePhotoCaptureSupported,
            supportedPhotoDimensions: device.activeFormat.supportedMaxPhotoDimensions
        )
    }

    private func configureReadinessCoordinator() {
        let delegate = ReadinessDelegate { [weak self] readiness in
            self?.captureReadiness = readiness
        }
        let coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        coordinator.delegate = delegate
        self.readinessDelegate = delegate
        self.readinessCoordinator = coordinator
    }
}

private class ReadinessDelegate: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    private let onChange: (AVCapturePhotoOutput.CaptureReadiness) -> Void

    init(onChange: @escaping (AVCapturePhotoOutput.CaptureReadiness) -> Void) {
        self.onChange = onChange
    }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        onChange(captureReadiness)
    }
}

typealias PhotoContinuation = CheckedContinuation<Photo, Error>

// MARK: - A photo capture delegate to process the captured photo.

/// An object that adopts the `AVCapturePhotoCaptureDelegate` protocol to respond to photo capture life-cycle events.
///
/// The delegate produces a stream of events that indicate its current state of processing.
private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    
    private let continuation: PhotoContinuation
    
    private var isLivePhoto = false
    private var isProxyPhoto = false
    
    private var photoData: Data?
    private var livePhotoMovieURL: URL?
    
    /// A stream of capture activity values that indicate the current state of progress.
    let activityStream: AsyncStream<CaptureActivity>
    private let activityContinuation: AsyncStream<CaptureActivity>.Continuation
    
    /// Creates a new delegate object with the checked continuation to call when processing is complete.
    init(continuation: PhotoContinuation) {
        self.continuation = continuation
        
        let (activityStream, activityContinuation) = AsyncStream.makeStream(of: CaptureActivity.self)
        self.activityStream = activityStream
        self.activityContinuation = activityContinuation
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Determine if this is a live capture.
        isLivePhoto = resolvedSettings.livePhotoMovieDimensions != .zero
        activityContinuation.yield(.photoCapture(isLivePhoto: isLivePhoto))
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Signal that a capture is beginning.
        activityContinuation.yield(.photoCapture(willCapture: true, isLivePhoto: isLivePhoto))
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL, resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Indicates that Live Photo capture is over.
        activityContinuation.yield(.photoCapture(isLivePhoto: false))
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            logger.debug("Error processing Live Photo companion movie: \(String(describing: error))")
        }
        livePhotoMovieURL = outputFileURL
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?, error: Error?) {
        if let error = error {
            logger.debug("Error capturing deferred photo: \(error)")
            return
        }
        // Capture the data for this photo.
        photoData = deferredPhotoProxy?.fileDataRepresentation()
        isProxyPhoto = true
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            logger.debug("Error capturing photo: \(String(describing: error))")
            return
        }
        photoData = photo.fileDataRepresentation()
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {

        defer {
            /// Finish the continuation to terminate the activity stream.
            activityContinuation.finish()
        }

        // If an error occurs, resume the continuation by throwing an error, and return.
        if let error {
            continuation.resume(throwing: error)
            return
        }
        
        // If the app captures no photo data, resume the continuation by throwing an error, and return.
        guard let photoData else {
            continuation.resume(throwing: PhotoCaptureError.noPhotoData)
            return
        }
        
        /// Create a photo object to save to the `MediaLibrary`.
        let photo = Photo(data: photoData, isProxy: isProxyPhoto, livePhotoMovieURL: livePhotoMovieURL)
        // Resume the continuation by returning the captured photo.
        continuation.resume(returning: photo)
    }
}
