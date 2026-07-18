import AVFoundation
import CoreImage
import CoreVideo
import Metal

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
