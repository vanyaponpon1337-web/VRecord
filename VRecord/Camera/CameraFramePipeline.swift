import AVFoundation
import Foundation
import os

/// All gesture state and frame bookkeeping belongs to CameraManager.frameQueue.
/// GPU completions return to that queue before touching shared application state.
final class CameraFramePipeline {
    private let queue: DispatchQueue
    private let tracking = HandTrackingManager()
    private var gestures = GestureStateMachine()
    private let compositor: MetalCompositor
    private let preview: SBSPreviewView
    private let recorder = VideoRecorder()
    private let photos = PhotoCaptureManager()
    private let library = MediaLibraryManager()
    private let log = Logger(subsystem: "com.vrecord.app", category: "Pipeline")
    private var redFrame: CVPixelBuffer?
    private var pinchSource: (buffer: CVPixelBuffer, hands: [HandLandmarks])?
    private var pendingStill: (buffer: CVPixelBuffer, hands: [HandLandmarks])?
    private var active = false
    private var generation = 0
    private var microphone = false
    private var finalizing = false
    private var interruptionCompletions: [() -> Void] = []

    init(queue: DispatchQueue, compositor: MetalCompositor, preview: SBSPreviewView) {
        self.queue = queue
        self.compositor = compositor
        self.preview = preview
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.log.error("Encoder failure: \(error.localizedDescription, privacy: .public)")
            self.interrupt()
        }
    }

    func activate(microphone: Bool) {
        queue.async {
            self.microphone = microphone
            self.active = true
            self.tracking.reset()
            self.gestures.cancelPending()
        }
    }

    /// Called on the camera's serial frame queue, never waits for Vision or GPU.
    func receive(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        tracking.submit(pixelBuffer: pixelBuffer, timestamp: now)
        let hands = tracking.snapshot(at: now).hands
        let previousState = gestures.state
        let actions = gestures.update(hands: hands, at: now)
        if gestures.state == .pinchPending && previousState == .idle {
            redFrame = nil
            pinchSource = nil
        }
        if hands.contains(where: { $0.pinching }) { pinchSource = (pixelBuffer, hands) }
        for action in actions {
            switch action {
            case .takePhoto:
                if let redFrame { capturePhoto(redFrame) }
                else if let pinchSource { pendingStill = pinchSource }
                redFrame = nil
                pinchSource = nil
            case .startRecording:
                do {
                    try recorder.start(width: CVPixelBufferGetWidth(pixelBuffer),
                                       height: CVPixelBufferGetHeight(pixelBuffer), audioEnabled: microphone)
                    preview.setRecording(true)
                } catch {
                    log.error("Cannot start recording: \(error.localizedDescription, privacy: .public)")
                    _ = gestures.interrupt()
                    gestures.finishFinalizing()
                    preview.setRecording(false)
                }
            case .stopRecording: finishRecording()
            }
        }
        let epoch = generation
        let hasRedSkeleton = hands.contains { $0.pinching }
        if let still = pendingStill {
            let submitted = compositor.composite(pixelBuffer: still.buffer, hands: still.hands) { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.capturePhoto(frame) }
            }
            if submitted { pendingStill = nil }
        }
        _ = compositor.composite(pixelBuffer: pixelBuffer, hands: hands) { [weak self] frame in
            guard let self else { return }
            self.queue.async {
                guard self.active, epoch == self.generation else { return }
                self.preview.submit(pixelBuffer: frame)
                if hasRedSkeleton { self.redFrame = frame }
                if self.gestures.isRecording {
                    self.recorder.appendVideo(pixelBuffer: frame, at: timestamp)
                }
            }
        }
        // Retain at most one gesture frame. A stale red frame is never used for
        // an unrelated photo: a new pending pinch replaces it before release.
        if hands.isEmpty { redFrame = nil }
    }

    func receiveAudio(_ sampleBuffer: CMSampleBuffer) { recorder.appendAudio(sampleBuffer) }

    func interrupt(completion: (() -> Void)? = nil) {
        queue.async {
            self.active = false
            self.generation += 1
            self.redFrame = nil
            self.pinchSource = nil
            self.pendingStill = nil
            self.tracking.reset()
            self.preview.clearFrame()
            self.compositor.flushUnusedResources()
            if let completion { self.interruptionCompletions.append(completion) }
            let actions = self.gestures.interrupt()
            if actions.contains(.stopRecording) || self.recorder.isRecording {
                self.finishRecording()
            } else if !self.finalizing {
                self.gestures.finishFinalizing()
                self.completeInterruption()
            }
        }
    }

    private func capturePhoto(_ frame: CVPixelBuffer) {
        photos.capture(pixelBuffer: frame) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.library.savePhoto(at: url) { result in
                    if case .failure(let error) = result {
                        self.log.error("Photo save failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            case .failure(let error):
                self.log.error("Photo encode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finishRecording() {
        preview.setRecording(false)
        guard !finalizing else { return }
        finalizing = true
        recorder.stop { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.library.saveVideo(at: url) { result in
                    if case .failure(let error) = result {
                        self.log.error("Video save failed: \(error.localizedDescription, privacy: .public)")
                    }
                    self.queue.async { self.didFinalize() }
                }
            case .failure(let error):
                self.log.error("Video finalization failed: \(error.localizedDescription, privacy: .public)")
                self.queue.async { self.didFinalize() }
            }
        }
    }

    private func didFinalize() {
        finalizing = false
        gestures.finishFinalizing()
        completeInterruption()
    }

    private func completeInterruption() {
        let callbacks = interruptionCompletions
        interruptionCompletions.removeAll()
        callbacks.forEach { $0() }
    }
}
