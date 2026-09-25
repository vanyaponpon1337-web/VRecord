import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var viewModel = CaptureExperienceViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if viewModel.cameraAuthorizationStatus == .authorized {
                CardboardSplitView(
                    cameraManager: viewModel.cameraManager,
                    skeleton: viewModel.handSkeleton,
                    showPhotoFlash: viewModel.showPhotoFlash,
                    interfaceOrientation: viewModel.interfaceOrientation
                )
            } else {
                CameraPermissionView(
                    authorizationStatus: viewModel.cameraAuthorizationStatus,
                    requestAccess: viewModel.start,
                    openSettings: viewModel.openSettings
                )
            }
        }
        .task {
            viewModel.start()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            viewModel.refreshInterfaceOrientation()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            viewModel.refreshInterfaceOrientation()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                viewModel.resumeIfAuthorized()
            case .inactive, .background:
                viewModel.suspend()
            @unknown default:
                viewModel.suspend()
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = viewModel.errorMessage,
               viewModel.cameraAuthorizationStatus == .authorized
            {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(.bottom, 16)
                    .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}
