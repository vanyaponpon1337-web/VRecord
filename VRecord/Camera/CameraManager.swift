import AVFoundation
import Combine
import Foundation
import ImageIO
import UIKit

final class CameraManager: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRecording = false
    @Published private(set) var videoAspectRatio: CGFloat = 16 / 9
    @Published private(set) var configuredFrameRate: Double = 0
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    var frameHandler: ((CMSampleBuffer, CGImagePropertyOrientation, CGFloat) -> Void)?

    private let sessionQueue = DispatchQueue(
        label: "com.example.VRecord.camera.session",
        qos: .userInitiated
    )
    private let videoOutputQueue = DispatchQueue(
        label: "com.example.VRecord.camera.frames",
        qos: .userInteractive
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let orientationLock = NSLock()
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight
    // AVCaptureVideoDataOutput receives hardware-rotated landscape buffers, so Vision can
    // consume them in their displayed orientation and its landmarks map directly to the preview.
    private var visionOrientation: CGImagePropertyOrientation = .right
    private var sourceAspectRatio: CGFloat = 16 / 9
    private var isConfigured = false
    private var hasRecordingRequest = false
    private var stopRecordingWhenStarted = false
    private var stopSessionAfterRecording = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func requestCameraAccess() async -> Bool {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        publishAuthorization(currentStatus)

        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    self?.publishAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.publishError("Camera access is required.")
                return
            }

            self.configureSessionIfNeeded()

            guard self.isConfigured, !self.session.isRunning else {
                return
            }

            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.hasRecordingRequest else {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                return
            }

            self.stopSessionAfterRecording = true
            self.requestStopRecording()
        }
    }

    func updateInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard let videoOrientation = orientation.captureVideoOrientation else {
            return
        }

        orientationLock.lock()
        interfaceOrientation = orientation
        visionOrientation = orientation.visionImageOrientation
        orientationLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.configureConnection(
                self.videoOutput.connection(with: .video),
                orientation: videoOrientation
            )
            self.configureConnection(
                self.photoOutput.connection(with: .video),
                orientation: videoOrientation
            )
            self.configureConnection(
                self.movieOutput.connection(with: .video),
                orientation: videoOrientation
            )
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning else {
                return
            }

            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.session.isRunning else {
                return
            }

            guard !self.hasRecordingRequest else {
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("VRecord-\(UUID().uuidString)")
                .appendingPathExtension("mov")

            self.hasRecordingRequest = true
            self.stopRecordingWhenStarted = false
            self.movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.requestStopRecording()
        }
    }

    func handleAppWillResignActive() {
        stop()
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        else {
            publishError("The rear wide-angle camera is unavailable on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                publishError("The rear camera input cannot be added to the capture session.")
                return
            }
            session.addInput(input)

            try configurePreferredFrameRate(on: camera)
        } catch {
            publishError("The camera could not be configured: \(error.localizedDescription)")
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)

        guard session.canAddOutput(videoOutput) else {
            publishError("The video frame output cannot be added to the capture session.")
            return
        }
        session.addOutput(videoOutput)

        photoOutput.isHighResolutionCaptureEnabled = true
        guard session.canAddOutput(photoOutput) else {
            publishError("The photo output cannot be added to the capture session.")
            return
        }
        session.addOutput(photoOutput)

        guard session.canAddOutput(movieOutput) else {
            publishError("The movie output cannot be added to the capture session.")
            return
        }
        session.addOutput(movieOutput)

        orientationLock.lock()
        let orientation = interfaceOrientation.captureVideoOrientation ?? .landscapeRight
        orientationLock.unlock()

        configureConnection(videoOutput.connection(with: .video), orientation: orientation)
        configureConnection(photoOutput.connection(with: .video), orientation: orientation)
        configureConnection(movieOutput.connection(with: .video), orientation: orientation)

        isConfigured = true
    }

    private func configurePreferredFrameRate(on device: AVCaptureDevice) throws {
        let targetFrameRate = 60.0
        let preferredPixelCount = Double(1920 * 1080)

        struct Candidate {
            let format: AVCaptureDevice.Format
            let range: AVFrameRateRange
            let frameRate: Double
            let pixelCount: Double
        }

        let candidates = device.formats.flatMap { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixelCount = Double(dimensions.width * dimensions.height)

            return format.videoSupportedFrameRateRanges.map { range in
                Candidate(
                    format: format,
                    range: range,
                    frameRate: min(max(targetFrameRate, range.minFrameRate), range.maxFrameRate),
                    pixelCount: pixelCount
                )
            }
        }

        guard let selection = candidates.min(by: { lhs, rhs in
            let leftFrameRateDistance = abs(lhs.frameRate - targetFrameRate)
            let rightFrameRateDistance = abs(rhs.frameRate - targetFrameRate)

            if leftFrameRateDistance != rightFrameRateDistance {
                return leftFrameRateDistance < rightFrameRateDistance
            }

            return abs(lhs.pixelCount - preferredPixelCount) < abs(rhs.pixelCount - preferredPixelCount)
        }) else {
            throw CameraConfigurationError.noUsableFrameRate
        }

        try device.lockForConfiguration()
        defer {
            device.unlockForConfiguration()
        }

        session.sessionPreset = .inputPriority
        device.activeFormat = selection.format
        device.isAutoVideoFrameRateEnabled = false

        let duration = CMTime(
            value: 600,
            timescale: CMTimeScale((selection.frameRate * 600).rounded())
        )
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        let dimensions = CMVideoFormatDescriptionGetDimensions(selection.format.formatDescription)
        let longestSide = CGFloat(max(dimensions.width, dimensions.height))
        let shortestSide = CGFloat(min(dimensions.width, dimensions.height))
        let aspectRatio = longestSide / shortestSide

        orientationLock.lock()
        sourceAspectRatio = aspectRatio
        orientationLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.configuredFrameRate = selection.frameRate
            self?.videoAspectRatio = aspectRatio
        }
    }

    private func configureConnection(
        _ connection: AVCaptureConnection?,
        orientation: AVCaptureVideoOrientation
    ) {
        guard let connection else {
            return
        }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func requestStopRecording() {
        guard hasRecordingRequest else {
            return
        }

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            stopRecordingWhenStarted = true
        }
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.publishError("Camera session was interrupted.")
            }
        )

        observers.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.publishError(error?.localizedDescription ?? "Camera session encountered an error.")
            }
        )
    }

    private func currentFrameMetadata() -> (CGImagePropertyOrientation, CGFloat) {
        orientationLock.lock()
        defer {
            orientationLock.unlock()
        }
        return (visionOrientation, sourceAspectRatio)
    }

    private func publishAuthorization(_ status: AVAuthorizationStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = status
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let metadata = currentFrameMetadata()
        frameHandler?(sampleBuffer, metadata.0, metadata.1)
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            publishError("Photo capture failed: \(error.localizedDescription)")
            return
        }

        guard let photoData = photo.fileDataRepresentation() else {
            publishError("Photo capture did not produce image data.")
            return
        }

        PhotoLibrarySaver.savePhotoData(photoData) { [weak self] result in
            if case let .failure(error) = result {
                self?.publishError("Photo could not be saved: \(error.localizedDescription)")
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = true
        }

        sessionQueue.async { [weak self] in
            guard let self, self.stopRecordingWhenStarted else {
                return
            }
            self.movieOutput.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.hasRecordingRequest = false
            self.stopRecordingWhenStarted = false

            if self.stopSessionAfterRecording {
                self.stopSessionAfterRecording = false
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
        }

        if let error {
            publishError("Video recording failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        PhotoLibrarySaver.saveVideo(at: outputFileURL) { [weak self] result in
            if case let .failure(error) = result {
                self?.publishError("Video could not be saved: \(error.localizedDescription)")
            }

            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }
}

private enum CameraConfigurationError: LocalizedError {
    case noUsableFrameRate

    var errorDescription: String? {
        switch self {
        case .noUsableFrameRate:
            "No compatible rear-camera frame-rate configuration is available."
        }
    }
}
