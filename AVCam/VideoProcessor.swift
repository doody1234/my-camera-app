import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

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
    fileprivate var metalProfileValue: Float {
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
    func beginRecording(to url: URL, width: Int, height: Int) throws {
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
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
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
}
