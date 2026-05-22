/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Extensions on AVFoundation capture and related types.
*/

import AVFoundation

extension CMVideoDimensions: @retroactive Equatable, @retroactive Comparable, @retroactive Hashable {

    static let zero = CMVideoDimensions()

    public static func == (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    public static func < (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width < rhs.width && lhs.height < rhs.height
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }

    var displayString: String {
        let dimWidth = Int(width)
        let dimHeight = Int(height)
        let megapixels: Double
        // Apply 4:3 crop only if the aspect ratio is wider than 4:3.
        if dimWidth * 3 > dimHeight * 4 {
            let croppedWidth = dimHeight * 4 / 3
            megapixels = Double(croppedWidth) * Double(dimHeight) / 1_000_000.0
        } else if dimHeight * 4 > dimWidth * 3 {
            let croppedHeight = dimWidth * 3 / 4
            megapixels = Double(dimWidth) * Double(croppedHeight) / 1_000_000.0
        } else {
            megapixels = Double(dimWidth) * Double(dimHeight) / 1_000_000.0
        }
        let rounded: Int
        if megapixels >= 24 {
            rounded = Int((megapixels / 2).rounded()) * 2
        } else {
            rounded = Int(megapixels.rounded())
        }
        return "\(rounded)MP"
    }
}

extension AVCaptureDevice {
    var activeFormat10BitVariant: AVCaptureDevice.Format? {
        formats.filter {
            $0.maxFrameRate == activeFormat.maxFrameRate &&
            $0.formatDescription.dimensions == activeFormat.formatDescription.dimensions
        }
        .first(where: { $0.isTenBitFormat })
    }
}

extension AVCaptureDevice.Format {
    var isTenBitFormat: Bool {
        formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    var maxFrameRate: Double {
        videoSupportedFrameRateRanges.last?.maxFrameRate ?? 0
    }
}

