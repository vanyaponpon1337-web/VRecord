import AVFoundation
import CoreVideo
import Foundation

/// Encodes the single-view, GPU-composited camera image, never the SBS display.
/// All inputs must use the AVCaptureSession source clock. Callers retain ownership
/// of the buffers, which this recorder retains only while bounded work is pending.
final class VideoRecorder {
    enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case unsupportedDimensions
        case unsupportedVideoSettings
        case unsupportedAudioSettings
        case writerFailed
        case noVideoSamples
        case noAudioSamples
        case invalidFrame

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A video is already recording or finishing."
            case .notRecording: return "There is no video to finish."
            case .unsupportedDimensions: return "The video dimensions must be positive and even."
            case .unsupportedVideoSettings: return "The device cannot encode this H.264 video format."
            case .unsupportedAudioSettings: return "The device cannot encode microphone audio as AAC."
            case .writerFailed: return "The video encoder could not write the recording."
            case .noVideoSamples: return "No composited camera frame was recorded."
            case .noAudioSamples: return "Microphone recording was enabled but no audio samples arrived."
            case .invalidFrame: return "The composited frame does not match the recording format."
            }
        }
    }

    /// Delivered on the main queue once if encoding fails during a recording.
    /// The owner should call stop to settle its gesture state and release the file.
    var onFailure: ((Error) -> Void)?

    private final class Session {
        let id = UUID()
        let url: URL
        let width: Int
        let height: Int
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: AVAssetWriterInput?
        var sourceTime: CMTime?
        var lastVideoTime: CMTime?
        var lastAudioTime: CMTime?
        var videoCount = 0
        var audioCount = 0
        var failure: Error?
        var finishing = false

        init(url: URL, width: Int, height: Int, writer: AVAssetWriter,
             video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audio: AVAssetWriterInput?) {
            self.url = url
            self.width = width
            self.height = height
            self.writer = writer
            self.video = video
            self.adaptor = adaptor
            self.audio = audio
        }
    }

    private let encodingQueue = DispatchQueue(label: "com.vrecord.encoding", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    // Readiness drops frames rather than retaining an expanding queue of camera buffers.
    private let videoSlots = DispatchSemaphore(value: 3)
    private let audioSlots = DispatchSemaphore(value: 12)
    private var acceptingSessionID: UUID?
    // Accessed only by encodingQueue, including finishWriting's completion handling.
    private var session: Session?

    var isRecording: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return acceptingSessionID != nil
    }

    /// Preparation is synchronous, so a thrown error cannot leave a false REC state.
    /// AVCaptureSession must already be delivering audio if audioEnabled is true.
    func start(width: Int, height: Int, audioEnabled: Bool) throws {
        try encodingQueue.sync {
            guard session == nil else { throw RecorderError.alreadyRecording }
            guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
                throw RecorderError.unsupportedDimensions
            }
            let url = try MediaFileStore.makeURL(fileExtension: "mp4")
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                writer.shouldOptimizeForNetworkUse = true
                // AVFoundation selects the supported iPhone H.264 hardware encoder.
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ],
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: min(35_000_000, max(4_000_000, width * height * 8)),
                        AVVideoExpectedSourceFrameRateKey: 60,
                        AVVideoMaxKeyFrameIntervalKey: 120,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoAllowFrameReorderingKey: false
                    ]
                ]
                guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                    throw RecorderError.unsupportedVideoSettings
                }
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                video.expectsMediaDataInRealTime = true
                guard writer.canAdd(video) else { throw RecorderError.unsupportedVideoSettings }
                writer.add(video)
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: video,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                    ]
                )
                var audio: AVAssetWriterInput?
                if audioEnabled {
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 96_000
                    ]
                    guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                        throw RecorderError.unsupportedAudioSettings
                    }
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw RecorderError.unsupportedAudioSettings }
                    writer.add(input)
                    audio = input
                }
                guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
                let newSession = Session(url: url, width: width, height: height, writer: writer,
                                         video: video, adaptor: adaptor, audio: audio)
                session = newSession
                lifecycleLock.lock()
                acceptingSessionID = newSession.id
                lifecycleLock.unlock()
            } catch {
                MediaFileStore.remove(url)
                throw error
            }
        }
    }

    /// Call only after Metal has finished rendering the image and skeleton pixels.
    func appendVideo(pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        guard timestamp.isNumeric, let id = submissionID(),
              videoSlots.wait(timeout: .now()) == .success else { return }
        encodingQueue.async { [self] in
            defer { videoSlots.signal() }
            autoreleasepool {
                guard let session = self.session, session.id == id,
                      session.failure == nil, !session.finishing else { return }
                guard CVPixelBufferGetWidth(pixelBuffer) == session.width,
                      CVPixelBufferGetHeight(pixelBuffer) == session.height,
                      CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
                    fail(session, with: RecorderError.invalidFrame)
                    return
                }
                guard session.writer.status == .writing else {
                    fail(session, with: session.writer.error ?? RecorderError.writerFailed)
                    return
                }
                if let last = session.lastVideoTime, CMTimeCompare(timestamp, last) <= 0 { return }
                guard session.video.isReadyForMoreMediaData else { return }
                if session.sourceTime == nil {
                    // Audio and video retain their original shared capture timestamps.
                    session.writer.startSession(atSourceTime: timestamp)
                    session.sourceTime = timestamp
                }
                if session.adaptor.append(pixelBuffer, withPresentationTime: timestamp) {
                    session.lastVideoTime = timestamp
                    session.videoCount += 1
                } else {
                    fail(session, with: session.writer.error ?? RecorderError.writerFailed)
                }
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let id = submissionID(),
              audioSlots.wait(timeout: .now()) == .success else { return }
        encodingQueue.async { [self] in
            defer { audioSlots.signal() }
            autoreleasepool {
                guard let session = self.session, session.id == id, session.failure == nil, !session.finishing,
                      let audio = session.audio, let sourceTime = session.sourceTime else { return }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard timestamp.isNumeric, CMTimeCompare(timestamp, sourceTime) >= 0 else { return }
                if let last = session.lastAudioTime, CMTimeCompare(timestamp, last) <= 0 { return }
                guard session.writer.status == .writing else {
                    fail(session, with: session.writer.error ?? RecorderError.writerFailed)
                    return
                }
                guard audio.isReadyForMoreMediaData else { return }
                if audio.append(sampleBuffer) {
                    session.lastAudioTime = timestamp
                    session.audioCount += 1
                } else {
                    fail(session, with: session.writer.error ?? RecorderError.writerFailed)
                }
            }
        }
    }

    /// Stops accepting frames immediately; completion arrives on the main queue
    /// only when the MP4 is finalized and safe to insert into Photos.
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        lifecycleLock.lock()
        let id = acceptingSessionID
        acceptingSessionID = nil
        lifecycleLock.unlock()
        encodingQueue.async { [self] in
            guard let session = self.session, id == nil || session.id == id else {
                finishCallback(completion, result: .failure(RecorderError.notRecording))
                return
            }
            // A second stop cannot mark inputs finished while finishWriting runs.
            guard !session.finishing else {
                finishCallback(completion, result: .failure(RecorderError.notRecording))
                return
            }
            guard session.writer.status == .writing else {
                if let failure = session.failure ?? session.writer.error {
                    discard(session, completion: completion, error: failure)
                } else {
                    finishCallback(completion, result: .failure(RecorderError.notRecording))
                }
                return
            }
            if let failure = session.failure {
                discard(session, completion: completion, error: failure)
                return
            }
            guard session.videoCount > 0, let lastVideo = session.lastVideoTime else {
                discard(session, completion: completion, error: RecorderError.noVideoSamples)
                return
            }
            guard session.audio == nil || session.audioCount > 0 else {
                discard(session, completion: completion, error: RecorderError.noAudioSamples)
                return
            }
            session.finishing = true
            session.writer.endSession(atSourceTime: CMTimeAdd(lastVideo, CMTime(value: 1, timescale: 60)))
            session.video.markAsFinished()
            session.audio?.markAsFinished()
            session.writer.finishWriting { [self] in
                encodingQueue.async { [self] in
                    guard self.session?.id == session.id else { return }
                    self.session = nil
                    if session.writer.status == .completed {
                        finishCallback(completion, result: .success(session.url))
                    } else {
                        MediaFileStore.remove(session.url)
                        finishCallback(completion, result: .failure(session.writer.error ?? RecorderError.writerFailed))
                    }
                }
            }
        }
    }

    private func submissionID() -> UUID? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return acceptingSessionID
    }

    private func fail(_ session: Session, with error: Error) {
        guard session.failure == nil else { return }
        session.failure = error
        lifecycleLock.lock()
        acceptingSessionID = nil
        lifecycleLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func discard(_ session: Session, completion: @escaping (Result<URL, Error>) -> Void, error: Error) {
        if session.writer.status == .writing { session.writer.cancelWriting() }
        self.session = nil
        MediaFileStore.remove(session.url)
        finishCallback(completion, result: .failure(error))
    }

    private func finishCallback(_ completion: @escaping (Result<URL, Error>) -> Void, result: Result<URL, Error>) {
        DispatchQueue.main.async { completion(result) }
    }
}
