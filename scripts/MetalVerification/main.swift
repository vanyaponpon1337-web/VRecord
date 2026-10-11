import CoreGraphics
import CoreVideo
import Foundation
import Metal

struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VerificationFailure(description: message) }
}

func cameraFixture(width: Int, height: Int) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                    attributes as CFDictionary, &created)
    guard status == kCVReturnSuccess, let buffer = created else {
        throw VerificationFailure(description: "Cannot allocate test camera buffer: \(status)")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw VerificationFailure(description: "Test camera buffer has no address")
    }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            // Four distinct quadrants detect flipping, mirroring, or stretching.
            row[x * 4] = 12
            row[x * 4 + 1] = y < height / 2 ? 30 : 180
            row[x * 4 + 2] = x < width / 2 ? 50 : 150
            row[x * 4 + 3] = 255
        }
    }
    return buffer
}

final class OutputBox {
    private let lock = NSLock()
    private var value: CVPixelBuffer?
    func set(_ buffer: CVPixelBuffer) { lock.lock(); value = buffer; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return value }
}

func composite(_ compositor: MetalCompositor, _ input: CVPixelBuffer, hands: [HandLandmarks]) throws -> CVPixelBuffer {
    let completed = DispatchSemaphore(value: 0)
    let output = OutputBox()
    try check(compositor.composite(pixelBuffer: input, hands: hands) { result in
        output.set(result)
        completed.signal()
    }, "Compositor rejected a test frame")
    try check(completed.wait(timeout: .now() + 10) == .success, "GPU did not produce a completed frame")
    guard let buffer = output.get() else { throw VerificationFailure(description: "Compositor returned no pixel buffer") }
    return buffer
}

func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> [Int] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else {
        throw VerificationFailure(description: "Composited frame has no address")
    }
    let p = address.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
    return (0..<4).map { Int(p[$0]) }
}

func expectPixel(_ buffer: CVPixelBuffer, x: Int, y: Int, bgra: [Int], context: String) throws {
    let actual = try pixel(buffer, x: x, y: y)
    try check(zip(actual, bgra).allSatisfy { pair in abs(pair.0 - pair.1) <= 2 }, "\(context): got BGRA \(actual), expected \(bgra)")
}

func verify() throws {
    try check(CommandLine.arguments.count == 2, "Pass the compiled Metal library path")
    guard MTLCreateSystemDefaultDevice() != nil else {
        // Some hosted/virtual macOS machines expose no GPU. The shader and Swift
        // compilation above remain mandatory; hardware pixel checks need Metal.
        print("SKIP GPU pixel verification: this macOS runner exposes no Metal device.")
        return
    }
    let compositor = try MetalCompositor(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    try check(MemoryLayout<SkeletonVertex>.stride == 32, "Swift/Metal skeleton vertex layout differs")
    let input = try cameraFixture(width: 256, height: 144)
    let plain = try composite(compositor, input, hands: [])
    try check(CVPixelBufferGetWidth(plain) == 256 && CVPixelBufferGetHeight(plain) == 144,
              "Export dimensions changed from the camera source")
    for (x, y, red, green) in [(20, 20, 50, 30), (230, 20, 150, 30),
                                (20, 120, 50, 180), (230, 120, 150, 180)] {
        try expectPixel(plain, x: x, y: y, bgra: [12, green, red, 255], context: "Camera quadrant (\(x),\(y))")
    }

    // Deterministic landmark fixtures exist only in this test executable.
    let left = HandLandmarks(id: 1, points: [.wrist: CGPoint(x: 0.2, y: 0.7),
                                            .indexMCP: CGPoint(x: 0.2, y: 0.3)], pinching: true)
    let right = HandLandmarks(id: 2, points: [.wrist: CGPoint(x: 0.7, y: 0.7),
                                             .indexMCP: CGPoint(x: 0.7, y: 0.3)], pinching: false)
    let overlaid = try composite(compositor, input, hands: [left, right])
    try expectPixel(overlaid, x: 51, y: 65, bgra: [0, 0, 255, 255], context: "Pinching skeleton baked red")
    try expectPixel(overlaid, x: 179, y: 65, bgra: [255, 255, 255, 255], context: "Other skeleton remains white")
    try expectPixel(overlaid, x: 20, y: 20, bgra: [12, 30, 50, 255], context: "Background camera pixels preserved")

    var released = left
    released.pinching = false
    let releasedFrame = try composite(compositor, input, hands: [released])
    try expectPixel(releasedFrame, x: 51, y: 65, bgra: [255, 255, 255, 255], context: "Released skeleton returns white")
    var otherPinching = right
    otherPinching.pinching = true
    let both = try composite(compositor, input, hands: [left, otherPinching])
    try expectPixel(both, x: 51, y: 65, bgra: [0, 0, 255, 255], context: "First simultaneous pinch")
    try expectPixel(both, x: 179, y: 65, bgra: [0, 0, 255, 255], context: "Second simultaneous pinch")
    compositor.flushUnusedResources()
    print("PASS actual Metal compositing: native dimensions, unmirrored camera quadrants, red/white skeleton pixels, independent hands, release, and simultaneous pinches.")
}

do {
    try verify()
} catch {
    FileHandle.standardError.write(Data("Metal verification failed: \(error)\n".utf8))
    exit(1)
}
