import AVFoundation
import UIKit
import os

/// Only the physical rear ultra-wide camera is accepted. Session configuration
/// never runs on the main thread; camera delivery has a separate bounded queue.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case ultraWideUnavailable, no60FPSFormat, cannotAttachOutput, invalidPixelFormat
        var errorDescription: String? {
            switch self {
            case .ultraWideUnavailable: return "Rear ultra-wide camera unavailable."
            case .no60FPSFormat: return "Ultra-wide camera has no compatible 60 FPS format."
            case .cannotAttachOutput: return "Unable to configure camera capture outputs."
            case .invalidPixelFormat: return "Camera does not support the Metal BGRA pipeline."
            }
        }
    }

    let session = AVCaptureSession()
    let frameQueue = DispatchQueue(label: "com.vrecord.frames", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.vrecord.session", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.vrecord.audio", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let log = Logger(subsystem: "com.vrecord.app", category: "Camera")
    private var configured = false
    private var requestedRunning = false
    private var orientation: UIInterfaceOrientation = .landscapeRight
    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onInterruption: (() -> Void)?
    var onResumed: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                             object: session, queue: nil) { [weak self] _ in
            self?.onInterruption?()
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                             object: session, queue: nil) { [weak self] _ in
            self?.resumeIfRequested()
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
                                             object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            self.onInterruption?()
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                self.onError?(error)
                if error.code == .mediaServicesWereReset { self.resumeIfRequested() }
            }
        })
    }

    func start(microphone: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedRunning = true
            do {
                if !self.configured { try self.configure(microphone: microphone) }
                if microphone { try self.activateAudio() }
                if !self.session.isRunning { self.session.startRunning() }
            } catch { self.onError?(error) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func setOrientation(_ value: UIInterfaceOrientation) {
        guard value.isLandscape else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.orientation = value
            self.applyOrientation()
        }
    }

    private func resumeIfRequested() {
        sessionQueue.async { [weak self] in
            guard let self, self.requestedRunning, self.configured else { return }
            do {
                if self.session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }) {
                    try self.activateAudio()
                }
                if !self.session.isRunning { self.session.startRunning() }
                self.onResumed?()
            } catch { self.onError?(error) }
        }
    }

    private func activateAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording,
                              options: [.defaultToSpeaker, .mixWithOthers])
        try audio.setPreferredSampleRate(48_000)
        try audio.setPreferredIOBufferDuration(0.01)
        try audio.setActive(true)
    }

    private func configure(microphone: Bool) throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera],
                                                         mediaType: .video, position: .back)
        guard let camera = discovery.devices.first else { throw CameraError.ultraWideUnavailable }
        // Prefer 1080p60 for sustainable Vision + GPU compositing + H.264 encoding.
        // If absent, rank every real 60 FPS format by distance from that pixel budget.
        let candidates = camera.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
        }
        let preferredPixels = 1920.0 * 1080.0
        guard let format = candidates.min(by: { lhs, rhs in
            func score(_ value: AVCaptureDevice.Format) -> Double {
                let size = CMVideoFormatDescriptionGetDimensions(value.formatDescription)
                let area = Double(size.width) * Double(size.height)
                let ratio = Double(size.width) / Double(size.height)
                return abs(log2(area / preferredPixels)) + abs(ratio - 16.0 / 9.0) * 2
            }
            return score(lhs) < score(rhs)
        }) else { throw CameraError.no60FPSFormat }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Failed prior configuration is fully retried, without duplicate inputs.
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresApplicationAudioSession = false
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input), session.canAddOutput(videoOutput) else { throw CameraError.cannotAttachOutput }
        session.addInput(input)
        session.addOutput(videoOutput)
        try camera.lockForConfiguration()
        camera.activeFormat = format
        // The shared BGRA pipeline and broadly compatible H.264 exports use SDR.
        if format.supportedColorSpaces.contains(.sRGB) { camera.activeColorSpace = .sRGB }
        camera.automaticallyAdjustsVideoHDREnabled = false
        camera.isVideoHDREnabled = false
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
        camera.unlockForConfiguration()
        guard videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) else {
            throw CameraError.invalidPixelFormat
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        applyOrientation()
        if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        if microphone {
            try activateAudio()
            guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.cannotAttachOutput }
            let micInput = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(micInput), session.canAddOutput(audioOutput) else { throw CameraError.cannotAttachOutput }
            session.addInput(micInput)
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        }
        configured = true
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log.info("Ultra-wide configured: \(size.width)x\(size.height), min/max duration \(camera.activeVideoMinFrameDuration.seconds)/\(camera.activeVideoMaxFrameDuration.seconds)")
    }

    private func applyOrientation() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        // AVFoundation physically rotates the buffers, so Vision, Metal, and
        // exports all share an upright, unmirrored landscape coordinate space.
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            onVideo?(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else if output === audioOutput { onAudio?(sampleBuffer) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
