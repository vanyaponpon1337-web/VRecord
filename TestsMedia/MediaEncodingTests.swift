import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import XCTest
@testable import VRecordMedia

/// Actual media round trips: these fixtures stand in for already-composited
/// camera pixels, while AVAssetWriter, ImageIO, AAC, and H.264 run normally.
/// Physical camera and Vision/Metal inference require the iPhone acceptance pass.
final class MediaEncodingTests: XCTestCase {
    private let width = 128
    private let height = 96

    func testPhotoKeepsBakedOverlayPixelsAndNativeDimensions() async throws {
        let buffer = try fixture()
        let manager = PhotoCaptureManager()
        let url = try await withCheckedThrowingContinuation { continuation in
            manager.capture(pixelBuffer: buffer) { continuation.resume(with: $0) }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(["heic", "jpg"].contains(url.pathExtension))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        let bytes = try rgbaPixels(image)
        let red = rgba(bytes, x: 64, y: 48)
        XCTAssertGreaterThan(red.r, 180)
        XCTAssertLessThan(red.g, 65)
        XCTAssertLessThan(red.b, 65)
        let black = rgba(bytes, x: 16, y: 48)
        XCTAssertLessThan(max(black.r, max(black.g, black.b)), 35)
        // One of these rows accommodates either bitmap drawing coordinate origin.
        let whiteRows = [22, height - 1 - 22].map { rgba(bytes, x: 24, y: $0) }
        XCTAssertTrue(whiteRows.contains { min($0.r, min($0.g, $0.b)) > 200 })
    }

    func testH264MP4KeepsOverlayAndIncludesFunctionalSynchronizedAAC() async throws {
        let recorder = VideoRecorder()
        let frame = try fixture()
        try recorder.start(width: width, height: height, audioEnabled: true)
        let sourceStart = CMTime(value: 10, timescale: 1)
        for index in 0..<30 {
            let timestamp = CMTimeAdd(sourceStart, CMTime(value: Int64(index), timescale: 60))
            recorder.appendVideo(pixelBuffer: frame, at: timestamp)
            recorder.appendAudio(try audioFixture(index: index, at: timestamp))
            // Pace a real-time writer without building an artificial input backlog.
            try await Task.sleep(nanoseconds: 17_000_000)
        }
        let url = try await stop(recorder)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertFalse(recorder.isRecording)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let encodedAudioFormats = try await audio.load(.formatDescriptions)
        XCTAssertTrue(encodedAudioFormats.contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC })
        let encodedVideoFormats = try await video.load(.formatDescriptions)
        XCTAssertTrue(encodedVideoFormats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.3)
        XCTAssertLessThan(duration.seconds, 0.8)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(videoOutput)
        reader.add(audioOutput)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "Reader failed to start")
        var count = 0
        var firstVideoPTS: CMTime?
        var previousPTS: CMTime?
        while let sample = videoOutput.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstVideoPTS == nil { firstVideoPTS = timestamp }
            if let previousPTS { XCTAssertGreaterThan(CMTimeCompare(timestamp, previousPTS), 0) }
            previousPTS = timestamp
            if count == 0 {
                let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                XCTAssertEqual(CVPixelBufferGetWidth(pixels), width)
                XCTAssertEqual(CVPixelBufferGetHeight(pixels), height)
                let red = try bgra(pixels, x: 64, y: 48)
                XCTAssertGreaterThan(red.r, 150)
                XCTAssertLessThan(red.g, 85)
                XCTAssertLessThan(red.b, 85)
            }
            count += 1
        }
        XCTAssertGreaterThan(count, 10)
        var firstAudioPTS: CMTime?
        var audioSampleCount = 0
        var audible = false
        while let sample = audioOutput.copyNextSampleBuffer() {
            if firstAudioPTS == nil { firstAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample) }
            audioSampleCount += CMSampleBufferGetNumSamples(sample)
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                var bytes = [UInt8](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBytes { data in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: data.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                audible = audible || bytes.contains { $0 != 0 }
            }
        }
        XCTAssertGreaterThan(audioSampleCount, 1_024)
        XCTAssertTrue(audible, "Decoded AAC must contain actual microphone-equivalent sample data")
        let audioStart = try XCTUnwrap(firstAudioPTS)
        let videoStart = try XCTUnwrap(firstVideoPTS)
        XCTAssertLessThan(abs(CMTimeSubtract(audioStart, videoStart).seconds), 0.1)
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Reader did not complete")
    }

    func testMicrophoneDeniedModeHasNoPretendAudioTrack() async throws {
        let recorder = VideoRecorder()
        let frame = try fixture()
        try recorder.start(width: width, height: height, audioEnabled: false)
        for index in 0..<6 {
            recorder.appendVideo(pixelBuffer: frame, at: CMTime(value: Int64(index), timescale: 60))
            try await Task.sleep(nanoseconds: 17_000_000)
        }
        let url = try await stop(recorder)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testEnabledAudioCannotReportSilentRecordingAsSuccess() async throws {
        let recorder = VideoRecorder()
        try recorder.start(width: width, height: height, audioEnabled: true)
        recorder.appendVideo(pixelBuffer: try fixture(), at: CMTime(value: 0, timescale: 60))
        try await Task.sleep(nanoseconds: 30_000_000)
        do {
            let url = try await stop(recorder)
            try? FileManager.default.removeItem(at: url)
            XCTFail("Missing audio must be reported instead of silently claiming audio was recorded")
        } catch {
            guard let recorderError = error as? VideoRecorder.RecorderError,
                  case .noAudioSamples = recorderError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func stop(_ recorder: VideoRecorder) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            recorder.stop { continuation.resume(with: $0) }
        }
    }

    private func fixture() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                          kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &result)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let red = (60..<68).contains(x)
                let white = (19..<26).contains(y) && !red
                bytes[offset] = white ? 255 : 0
                bytes[offset + 1] = white ? 255 : 0
                bytes[offset + 2] = red || white ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private func audioFixture(index: Int, at timestamp: CMTime) throws -> CMSampleBuffer {
        let sampleCount = 800 // 48,000 Hz / 60 video frames per second.
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                       magicCookie: nil, extensions: nil,
                                                       formatDescriptionOut: &format), noErr)
        let description = try XCTUnwrap(format)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                          blockLength: sampleCount * 2, blockAllocator: kCFAllocatorDefault,
                                                          customBlockSource: nil, offsetToData: 0, dataLength: sampleCount * 2,
                                                          flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let dataBlock = try XCTUnwrap(block)
        let samples: [Int16] = (0..<sampleCount).map { sample in
            let phase = Double(index * sampleCount + sample) * 2 * Double.pi * 440 / 48_000
            return Int16(sin(phase) * 8_000)
        }
        let copyStatus = samples.withUnsafeBytes { data in
            CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: dataBlock,
                                          offsetIntoDestination: 0, dataLength: sampleCount * 2)
        }
        XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: dataBlock,
                                                 formatDescription: description, sampleCount: sampleCount,
                                                 sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                                 sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func rgba(_ bytes: [UInt8], x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func bgra(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (data[offset + 2], data[offset + 1], data[offset])
    }
}
