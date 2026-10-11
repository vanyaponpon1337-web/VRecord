import CoreVideo
import Foundation
import Metal

enum MetalRenderingError: LocalizedError {
    case unavailable
    case shaderLibrary
    case allocation

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Metal is unavailable on this device."
        case .shaderLibrary: return "The bundled Metal shaders could not be loaded."
        case .allocation: return "Metal rendering resources could not be allocated."
        }
    }
}

/// Produces the single-view BGRA image used by preview, photos, and video.
/// Calls never wait for the GPU. A full GPU or pixel-buffer pool drops that frame.
final class MetalCompositor {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let cameraPipeline: MTLRenderPipelineState
    let skeletonPipeline: MTLRenderPipelineState
    let indicatorPipeline: MTLRenderPipelineState

    private let textureCache: CVMetalTextureCache
    private let textureLock = NSLock()
    private let resourceLock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private let slots: [MeshSlot]
    private let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
    private let readTextureAttributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue] as CFDictionary
    private let renderTextureAttributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.union(.renderTarget).rawValue] as CFDictionary

    private final class MeshSlot {
        let buffer: MTLBuffer
        var busy = false
        init(buffer: MTLBuffer) { self.buffer = buffer }
    }

    init(libraryURL: URL? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw MetalRenderingError.unavailable }
        let library: MTLLibrary
        if let libraryURL {
            library = try device.makeLibrary(URL: libraryURL)
        } else {
            guard let bundledLibrary = device.makeDefaultLibrary() else { throw MetalRenderingError.shaderLibrary }
            library = bundledLibrary
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalRenderingError.allocation }

        func pipeline(vertex: String, fragment: String, blending: Bool = false) throws -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                throw MetalRenderingError.shaderLibrary
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.device = device
        commandQueue = queue
        textureCache = cache
        cameraPipeline = try pipeline(vertex: "vrecord_camera_vertex", fragment: "vrecord_camera_fragment")
        skeletonPipeline = try pipeline(vertex: "vrecord_skeleton_vertex", fragment: "vrecord_skeleton_fragment")
        indicatorPipeline = try pipeline(vertex: "vrecord_indicator_vertex", fragment: "vrecord_indicator_fragment", blending: true)
        var createdSlots: [MeshSlot] = []
        for _ in 0..<2 {
            guard let buffer = device.makeBuffer(length: SkeletonRenderer.maximumVertexCount * MemoryLayout<SkeletonVertex>.stride,
                                                 options: .storageModeShared) else { throw MetalRenderingError.allocation }
            buffer.label = "VRecord reusable hand mesh"
            createdSlots.append(MeshSlot(buffer: buffer))
        }
        slots = createdSlots
    }

    /// Completion runs on a Metal completion thread only after all pixels are ready.
    /// Retain the delivered buffer for as long as an encoder or photo needs it.
    @discardableResult
    func composite(pixelBuffer: CVPixelBuffer, hands: [HandLandmarks],
                   completion: @escaping (CVPixelBuffer) -> Void) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let slot = acquireSlot() else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let output = allocateBuffer(width: width, height: height),
              let source = makeTexture(pixelBuffer),
              let destination = makeTexture(output, renderTarget: true),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            releaseSlot(slot)
            return false
        }
        CVBufferPropagateAttachments(pixelBuffer, output)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            releaseSlot(slot)
            return false
        }
        commandBuffer.label = "VRecord single-view compositing"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setFragmentTexture(source.texture, index: 0)
        var fullImage = SIMD4<Float>(0, 0, 1, 1)
        encoder.setFragmentBytes(&fullImage, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        let count = SkeletonRenderer.write(hands: hands, width: width, height: height, into: slot.buffer)
        if count > 0 {
            encoder.setRenderPipelineState(skeletonPipeline)
            encoder.setVertexBuffer(slot.buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [self, pixelBuffer, output, source, destination, slot] completed in
            // Core Video texture wrappers and camera storage must outlive GPU use.
            withExtendedLifetime((pixelBuffer, source.cvTexture, destination.cvTexture)) {
                releaseSlot(slot)
                if completed.status == .completed { completion(output) }
            }
        }
        commandBuffer.commit()
        return true
    }

    struct PixelTexture {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    func makeTexture(_ buffer: CVPixelBuffer, renderTarget: Bool = false) -> PixelTexture? {
        var wrapped: CVMetalTexture?
        textureLock.lock()
        let attributes = renderTarget ? renderTextureAttributes : readTextureAttributes
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, attributes,
                                                              .bgra8Unorm, CVPixelBufferGetWidth(buffer),
                                                              CVPixelBufferGetHeight(buffer), 0, &wrapped)
        textureLock.unlock()
        guard status == kCVReturnSuccess, let wrapped,
              let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
        return PixelTexture(cvTexture: wrapped, texture: texture)
    }

    func flushUnusedResources() {
        resourceLock.lock()
        if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) }
        resourceLock.unlock()
        textureLock.lock()
        CVMetalTextureCacheFlush(textureCache, 0)
        textureLock.unlock()
    }

    private func acquireSlot() -> MeshSlot? {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        guard let slot = slots.first(where: { !$0.busy }) else { return nil }
        slot.busy = true
        return slot
    }

    private func releaseSlot(_ slot: MeshSlot) {
        resourceLock.lock()
        slot.busy = false
        resourceLock.unlock()
    }

    private func allocateBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        if pool == nil || width != poolWidth || height != poolHeight {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, attributes as CFDictionary, &newPool) == kCVReturnSuccess,
                  let newPool else { return nil }
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var result: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationAttributes, &result)
        return status == kCVReturnSuccess ? result : nil
    }
}
