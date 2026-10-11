import AVFoundation
import UIKit
import os

final class AppLifecycle {
    let viewController: ImmersiveViewController
    private let camera = CameraManager()
    private let pipeline: CameraFramePipeline
    private var authorized = false
    private var microphone = false
    private var lastOrientation: UIInterfaceOrientation = .landscapeRight
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.vrecord.app", category: "Lifecycle")

    init() throws {
        let compositor = try MetalCompositor()
        let preview = SBSPreviewView(compositor: compositor)
        viewController = ImmersiveViewController()
        viewController.view = preview
        pipeline = CameraFramePipeline(queue: camera.frameQueue, compositor: compositor, preview: preview)
        pipeline.onRecovery = { [weak self] in DispatchQueue.main.async { self?.foreground() } }
        camera.onVideo = { [weak self] in self?.pipeline.receive(pixelBuffer: $0, timestamp: $1) }
        camera.onAudio = { [weak self] in self?.pipeline.receiveAudio($0) }
        camera.onInterruption = { [weak self] in
            guard let self else { return }
            self.pipeline.interrupt()
        }
        camera.onResumed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, UIApplication.shared.applicationState == .active else { return }
                self.pipeline.activate(microphone: self.microphone)
            }
        }
        camera.onError = { [weak self] error in self?.log.error("Capture error: \(error.localizedDescription, privacy: .public)") }
        viewController.onOrientation = { [weak self] value in
            guard let self else { return }
            if value != self.lastOrientation {
                self.pipeline.interrupt { [weak self] in DispatchQueue.main.async { self?.foreground() } }
                self.lastOrientation = value
            }
            self.camera.setOrientation(value)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { self.pipeline.interrupt(); self.camera.stop() }
            else { self.foreground() }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                             object: camera.session, queue: .main) { [weak self] _ in self?.foreground() })
    }

    func requestPermissionsAndStart() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let access = await PermissionsManager.requestCapturePermissions()
            self.authorized = access.camera
            self.microphone = access.microphone
            if !access.camera { self.log.error("Camera permission denied.") }
            if !access.microphone { self.log.notice("Microphone unavailable; video will have no audio track.") }
            self.foreground()
        }
    }

    func foreground() {
        guard authorized, UIApplication.shared.applicationState == .active else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        pipeline.activate(microphone: microphone)
        camera.start(microphone: microphone)
    }

    func resignActive() {
        // System prompts also resign active. Unstarted pipelines tolerate this.
        pipeline.interrupt()
    }

    func background() {
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finalize VRecord video") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        pipeline.interrupt { [weak self] in DispatchQueue.main.async { self?.endBackgroundTask() } }
        camera.stop()
    }

    func memoryWarning() { pipeline.interrupt { [weak self] in DispatchQueue.main.async { self?.foreground() } } }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
