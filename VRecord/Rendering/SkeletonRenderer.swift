import CoreGraphics
import Foundation
import Metal
import simd

struct SkeletonVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Creates only a small triangle mesh on the CPU. All image pixels stay on the GPU.
enum SkeletonRenderer {
    static let maximumVertexCount = 4096

    static func write(hands: [HandLandmarks], width: Int, height: Int, into buffer: MTLBuffer) -> Int {
        let vertices = buffer.contents().bindMemory(to: SkeletonVertex.self, capacity: maximumVertexCount)
        var count = 0
        let imageSize = SIMD2<Float>(Float(width), Float(height))
        let lineWidth = max(2, Float(min(width, height)) * 0.0024)
        let jointRadius = lineWidth * 2.0
        let circleSegments = 16

        func clip(_ point: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(point.x / imageSize.x * 2 - 1, 1 - point.y / imageSize.y * 2)
        }

        func pixelPoint(_ point: CGPoint) -> SIMD2<Float>? {
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
            return SIMD2<Float>(Float(point.x), Float(point.y)) * imageSize
        }

        func triangle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: SIMD4<Float>) {
            guard count + 3 <= maximumVertexCount else { return }
            vertices[count] = SkeletonVertex(position: clip(a), color: color)
            vertices[count + 1] = SkeletonVertex(position: clip(b), color: color)
            vertices[count + 2] = SkeletonVertex(position: clip(c), color: color)
            count += 3
        }

        for hand in hands.prefix(2) {
            let color = hand.pinching ? SIMD4<Float>(1, 0, 0, 1) : SIMD4<Float>(1, 1, 1, 1)
            for (start, end) in HandLandmarks.bones {
                guard let startPoint = hand.points[start], let endPoint = hand.points[end],
                      let a = pixelPoint(startPoint), let b = pixelPoint(endPoint) else { continue }
                let delta = b - a
                let length = simd_length(delta)
                guard length > 0.01 else { continue }
                let normal = SIMD2<Float>(-delta.y, delta.x) * (lineWidth * 0.5 / length)
                triangle(a - normal, b - normal, a + normal, color: color)
                triangle(a + normal, b - normal, b + normal, color: color)
            }
            // Small round joints also provide clean round joins and line ends.
            for point in hand.points.values {
                guard let center = pixelPoint(point) else { continue }
                for segment in 0..<circleSegments {
                    let a = Float(segment) * 2 * .pi / Float(circleSegments)
                    let b = Float(segment + 1) * 2 * .pi / Float(circleSegments)
                    triangle(center,
                             center + SIMD2<Float>(cos(a), sin(a)) * jointRadius,
                             center + SIMD2<Float>(cos(b), sin(b)) * jointRadius,
                             color: color)
                }
            }
        }
        return count
    }
}
