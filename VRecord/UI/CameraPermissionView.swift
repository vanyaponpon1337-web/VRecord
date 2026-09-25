import AVFoundation
import SwiftUI

struct CameraPermissionView: View {
    let authorizationStatus: AVAuthorizationStatus
    let requestAccess: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 46))
                .foregroundStyle(.white)

            Text("Camera Access Required")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button(action: buttonAction) {
                Text(buttonTitle)
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private var message: String {
        switch authorizationStatus {
        case .denied, .restricted:
            "VRecord needs the rear camera for its live Cardboard preview and hand controls. Enable Camera access in Settings to continue."
        case .notDetermined:
            "VRecord uses the rear camera for its live Cardboard preview and hand controls."
        case .authorized:
            ""
        @unknown default:
            "Camera access is unavailable. Check Settings and try again."
        }
    }

    private var buttonTitle: String {
        authorizationStatus == .notDetermined ? "Allow Camera" : "Open Settings"
    }

    private func buttonAction() {
        if authorizationStatus == .notDetermined {
            requestAccess()
        } else {
            openSettings()
        }
    }
}
