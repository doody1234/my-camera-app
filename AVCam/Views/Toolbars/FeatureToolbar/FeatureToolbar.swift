/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that presents controls to enable capture features.
*/

import SwiftUI
import AVFoundation

/// A view that presents controls to enable capture features.
struct FeaturesToolbar<CameraModel: Camera>: PlatformView {
    
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    @State var camera: CameraModel
    
    var body: some View {
        HStack(spacing: 30) {
            switch camera.captureMode {
            case .photo:
                resolutionPicker
                Spacer()
                livePhotoButton
                prioritizePicker
                settingsMenu
            case .video:
                Spacer()
                if camera.isHDRVideoSupported {
                    hdrButton
                }
            }
        }
        .buttonStyle(DefaultButtonStyle(size: isRegularSize ? .large : .small))
        .padding([.leading, .trailing])
        .opacity(camera.prefersMinimizedUI ? 0 : 1)
    }
    
    //  A button to toggle the enabled state of Live Photo capture.
    var livePhotoButton: some View {
        Button {
            camera.isLivePhotoEnabled.toggle()
        } label: {
            Image(systemName: camera.isLivePhotoEnabled ? "livephoto" : "livephoto.slash")
        }
    }

    @ViewBuilder
    var resolutionPicker: some View {
        if camera.supportedPhotoDimensions.count > 1 {
            ForEach(camera.supportedPhotoDimensions, id: \.self) { dimensions in
                Button {
                    Task { await camera.selectMaxPhotoDimensions(dimensions) }
                } label: {
                    Text(dimensions.displayString)
                        .font(.caption2.weight(.semibold))
                }
                .opacity(camera.maxPhotoDimensions == dimensions ? 1.0 : 0.5)
            }
        }
    }

    @ViewBuilder
    var prioritizePicker: some View {
        Menu {
            Picker("Quality Prioritization", selection: $camera.qualityPrioritization) {
                ForEach(QualityPrioritization.allCases) {
                    Text($0.description)
                        .font(.body.weight(.bold))
                }
            }

        } label: {
            switch camera.qualityPrioritization {
            case .speed:
                Image(systemName: "dial.low")
            case .balanced:
                Image(systemName: "dial.medium")
            case .quality:
                Image(systemName: "dial.high")
            }
        }
    }

    @ViewBuilder
    var hdrButton: some View {
        if isCompactSize {
            hdrToggleButton
        } else {
            hdrToggleButton
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
    
    var hdrToggleButton: some View {
        Button {
            camera.isHDRVideoEnabled.toggle()
        } label: {
            Text("HDR \(camera.isHDRVideoEnabled ? "On" : "Off")")
                .font(.body.weight(.semibold))
        }
        .disabled(camera.captureActivity.isRecording)
    }
    
    var settingsMenu: some View {
        Menu {
            Button {
                camera.isDeferredProcessingEnabled.toggle()
            } label: {
                Label("Deferred Processing", systemImage: camera.isDeferredProcessingEnabled ? "checkmark.circle.fill" : "circle")
            }
            Button {
                camera.isResponsiveCaptureEnabled.toggle()
            } label: {
                Label("Responsive Shutter", systemImage: camera.isResponsiveCaptureEnabled ? "checkmark.circle.fill" : "circle")
            }
            Button {
                camera.isFastCapturePrioritizationEnabled.toggle()
            } label: {
                Label("Fast Capture", systemImage: camera.isFastCapturePrioritizationEnabled ? "checkmark.circle.fill" : "circle")
            }
        } label: {
            Image(systemName: "gearshape")
        }
    }

    @ViewBuilder
    var compactSpacer: some View {
        if !isRegularSize {
            Spacer()
        }
    }
}
