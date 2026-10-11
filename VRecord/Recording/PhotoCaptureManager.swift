import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Encodes an already-composited, single-view frame at its original dimensions.
/// Keeping the source CVPixelBuffer alive also keeps a pooled Metal output from
/// being reused until the image has been read by Core Image.
final class PhotoCaptureManager {
    enum CaptureError: LocalizedError {
        case busy
        case invalidImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .busy: return "Two photos are already being processed."
            case .invalidImage: return "The composited camera image could not be read."
            case .encodingFailed: return "The composited photo could not be encoded."
            }
        }
    }

    private let encodingQueue = DispatchQueue(label: "com.vrecord.photo", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 2)
    private let context: CIContext
    private let colorSpace: CGColorSpace

    init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        self.colorSpace = colorSpace
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// This method never blocks camera capture. Pass a buffer after its Metal
    /// command completes; the hand skeletons must already be baked into its pixels.
    /// Completion is delivered on the main queue with a temporary HEIC/JPEG URL.
    func capture(pixelBuffer: CVPixelBuffer, completion: @escaping (Result<URL, Error>) -> Void) {
        guard slots.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { completion(.failure(CaptureError.busy)) }
            return
        }
        encodingQueue.async { [self] in
            defer { slots.signal() }
            let result: Result<URL, Error> = autoreleasepool {
                let image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: colorSpace])
                guard let cgImage = context.createCGImage(image, from: image.extent,
                                                         format: .RGBA8, colorSpace: colorSpace) else {
                    return .failure(CaptureError.invalidImage)
                }
                do {
                    let url: URL
                    // iPhone supports HEIC; JPEG remains a compatible fallback if
                    // an ImageIO encoder rejects the current image or is unavailable.
                    if let heic = try? write(cgImage, type: .heic, fileExtension: "heic") {
                        url = heic
                    } else {
                        url = try write(cgImage, type: .jpeg, fileExtension: "jpg")
                    }
                    return .success(url)
                } catch {
                    return .failure(error)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func write(_ image: CGImage, type: UTType, fileExtension: String) throws -> URL {
        let url = try MediaFileStore.makeURL(fileExtension: fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            MediaFileStore.remove(url)
            throw CaptureError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.94,
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            MediaFileStore.remove(url)
            throw CaptureError.encodingFailed
        }
        return url
    }
}
