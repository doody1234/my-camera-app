import Metal
import CoreVideo

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

        // Load the shader library from the string in Shaders.swift instead of a file
        guard
            let library = try? device.makeLibrary(source: Shaders.source, options: nil),
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

    /// Renders `pixelBuffer` through the log filter and returns a freshly
    /// allocated output buffer in the same 10-bit biplanar format.
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