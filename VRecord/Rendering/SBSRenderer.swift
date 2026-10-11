import CoreVideo
import MetalKit
import UIKit

/// Fullscreen monoscopic stereo preview. Both eye draws always use one snapshot.
final class SBSPreviewView: MTKView {
    private var renderer: SBSRenderer!

    init(compositor: MetalCompositor) {
        super.init(frame: .zero, device: compositor.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        renderer = SBSRenderer(compositor: compositor)
        delegate = renderer
    }

    required init(coder: NSCoder) { fatalError("SBSPreviewView uses programmatic initialization.") }

    /// Safe to call from the GPU completion queue. Older undrawn frames are replaced.
    func submit(pixelBuffer: CVPixelBuffer) { renderer.submit(pixelBuffer: pixelBuffer) }

    /// Safe to call from the gesture/recording queue.
    func setRecording(_ recording: Bool) { renderer.setRecording(recording) }

    func clearFrame() { renderer.clearFrame() }
}

final class SBSRenderer: NSObject, MTKViewDelegate {
    private let compositor: MetalCompositor
    private let stateLock = NSLock()
    private let gpuSlot = DispatchSemaphore(value: 1)
    private var latest: PreviewFrame?
    private var recording = false

    private struct PreviewFrame {
        let pixelBuffer: CVPixelBuffer
        let wrappedTexture: MetalCompositor.PixelTexture
    }

    init(compositor: MetalCompositor) {
        self.compositor = compositor
        super.init()
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        guard let texture = compositor.makeTexture(pixelBuffer) else { return }
        let frame = PreviewFrame(pixelBuffer: pixelBuffer, wrappedTexture: texture)
        stateLock.lock()
        latest = frame
        stateLock.unlock()
    }

    func setRecording(_ value: Bool) {
        stateLock.lock()
        recording = value
        stateLock.unlock()
    }

    func clearFrame() {
        stateLock.lock()
        latest = nil
        recording = false
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard gpuSlot.wait(timeout: .now()) == .success else { return }
        stateLock.lock()
        let snapshot = latest
        let showRecording = recording
        stateLock.unlock()
        guard let frame = snapshot, view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = compositor.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            gpuSlot.signal()
            return
        }
        commandBuffer.label = "VRecord synchronized SBS preview"
        let eyeWidth = Double(drawable.texture.width) / 2
        let eyeHeight = Double(drawable.texture.height)
        let imageAspect = Float(frame.wrappedTexture.texture.width) / Float(frame.wrappedTexture.texture.height)
        let eyeAspect = Float(eyeWidth / eyeHeight)
        var crop = SIMD4<Float>(0, 0, 1, 1)
        if imageAspect > eyeAspect {
            crop.z = eyeAspect / imageAspect
            crop.x = (1 - crop.z) * 0.5
        } else {
            crop.w = imageAspect / eyeAspect
            crop.y = (1 - crop.w) * 0.5
        }

        let scale = Float(view.contentScaleFactor)
        let center = Float(22) * scale
        let radius = Float(9) * scale
        var circle = SIMD4<Float>(center / Float(eyeWidth) * 2 - 1,
                                  1 - center / Float(eyeHeight) * 2,
                                  radius / Float(eyeWidth) * 2,
                                  radius / Float(eyeHeight) * 2)
        for eye in 0..<2 {
            encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0,
                                             width: eyeWidth, height: eyeHeight, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(compositor.cameraPipeline)
            encoder.setFragmentTexture(frame.wrappedTexture.texture, index: 0)
            encoder.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if showRecording {
                encoder.setRenderPipelineState(compositor.indicatorPipeline)
                encoder.setVertexBytes(&circle, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [self, frame] _ in
            withExtendedLifetime(frame) { _ = gpuSlot.signal() }
        }
        commandBuffer.commit()
    }
}
