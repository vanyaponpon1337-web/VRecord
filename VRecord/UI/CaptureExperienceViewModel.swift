import AVFoundation
import Combine
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class CaptureExperienceViewModel: ObservableObject {
    @Published private(set) var handSkeleton: HandSkeleton?
    @Published private(set) var showPhotoFlash = false
    @Published private(set) var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var interfaceOrientation: UIInterfaceOrientation = .landscapeRight
    @Published private(set) var errorMessage: String?

    let cameraManager: CameraManager

    private let handTrackingManager: HandTrackingManager
    private var captureStateMachine = CaptureStateMachine()
    private var cancellables = Set<AnyCancellable>()
    private var longPressWorkItem: DispatchWorkItem?
    private var flashWorkItem: DispatchWorkItem?

    init(
        cameraManager: CameraManager = CameraManager(),
        handTrackingManager: HandTrackingManager = HandTrackingManager()
    ) {
        self.cameraManager = cameraManager
        self.handTrackingManager = handTrackingManager

        cameraManager.frameHandler = { [weak handTrackingManager] sampleBuffer, orientation, sourceAspectRatio in
            handTrackingManager?.enqueue(
                sampleBuffer: sampleBuffer,
                orientation: orientation,
                sourceAspectRatio: sourceAspectRatio
            )
        }

        handTrackingManager.onHandUpdate = { [weak self] hand in
            DispatchQueue.main.async {
                self?.receive(hand)
            }
        }

        cameraManager.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.cameraAuthorizationStatus = status
            }
            .store(in: &cancellables)

        cameraManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.errorMessage = message
            }
            .store(in: &cancellables)
    }

    func start() {
        refreshInterfaceOrientation()

        Task { [weak self] in
            guard let self else {
                return
            }

            let hasAccess = await cameraManager.requestCameraAccess()
            guard hasAccess else {
                return
            }

            cameraManager.start()
        }
    }

    func resumeIfAuthorized() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return
        }

        refreshInterfaceOrientation()
        cameraManager.start()
    }

    func suspend() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        execute(captureStateMachine.cancel())
        handTrackingManager.reset()
        handSkeleton = nil
        cameraManager.handleAppWillResignActive()
    }

    func refreshInterfaceOrientation() {
        let sceneOrientations = UIApplication.shared.connectedScenes.compactMap {
            ($0 as? UIWindowScene)?.interfaceOrientation
        }
        guard let landscapeOrientation = sceneOrientations.first(where: \.isLandscape) else {
            return
        }

        interfaceOrientation = landscapeOrientation
        cameraManager.updateInterfaceOrientation(landscapeOrientation)
    }

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

    private func receive(_ skeleton: HandSkeleton?) {
        handSkeleton = skeleton
        let now = CACurrentMediaTime()
        let isPinching = skeleton?.isPinching ?? false

        execute(captureStateMachine.update(pinchIsActive: isPinching, at: now))
        synchronizeLongPressTimer(at: now)
    }

    private func synchronizeLongPressTimer(at timestamp: TimeInterval) {
        guard case let .pinching(startTime) = captureStateMachine.state else {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
            return
        }

        guard longPressWorkItem == nil else {
            return
        }

        let remainingDuration = max(
            0.002,
            captureStateMachine.longPressDuration - (timestamp - startTime) + 0.002
        )
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleLongPressTimer(startTime: startTime)
        }

        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + remainingDuration,
            execute: workItem
        )
    }

    private func handleLongPressTimer(startTime: TimeInterval) {
        longPressWorkItem = nil

        guard case let .pinching(activeStartTime) = captureStateMachine.state,
              abs(activeStartTime - startTime) < 0.001
        else {
            return
        }

        execute(captureStateMachine.advance(at: CACurrentMediaTime()))
        synchronizeLongPressTimer(at: CACurrentMediaTime())
    }

    private func execute(_ action: CaptureAction) {
        switch action {
        case .none:
            break
        case .capturePhoto:
            presentPhotoFlash()
            cameraManager.capturePhoto()
        case .startRecording:
            cameraManager.startRecording()
        case .stopRecording:
            cameraManager.stopRecording()
        }
    }

    private func presentPhotoFlash() {
        flashWorkItem?.cancel()
        showPhotoFlash = true

        let workItem = DispatchWorkItem { [weak self] in
            self?.showPhotoFlash = false
        }
        flashWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}
