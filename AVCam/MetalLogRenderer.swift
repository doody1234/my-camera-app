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
}
