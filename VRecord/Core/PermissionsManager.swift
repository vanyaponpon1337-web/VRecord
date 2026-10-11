import AVFoundation
import Foundation

enum PermissionsManager {
    static func requestCapturePermissions() async -> (camera: Bool, microphone: Bool) {
        let camera = await request(.video)
        guard camera else { return (false, false) }
        let microphone = await request(.audio)
        return (camera, microphone)
    }

    private static func request(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}
