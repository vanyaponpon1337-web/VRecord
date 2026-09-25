import Foundation
import Photos

enum PhotoLibrarySaveError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos access is required to save captures."
        }
    }
}

enum PhotoLibrarySaver {
    static func savePhotoData(
        _ data: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        requestAddOnlyAuthorization { result in
            switch result {
            case .failure:
                completion(.failure(PhotoLibrarySaveError.permissionDenied))
            case .success:
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                } completionHandler: { success, error in
                    completion(success ? .success(()) : .failure(error ?? PhotoLibrarySaveError.permissionDenied))
                }
            }
        }
    }

    static func saveVideo(
        at fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        requestAddOnlyAuthorization { result in
            switch result {
            case .failure:
                completion(.failure(PhotoLibrarySaveError.permissionDenied))
            case .success:
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: fileURL, options: nil)
                } completionHandler: { success, error in
                    completion(success ? .success(()) : .failure(error ?? PhotoLibrarySaveError.permissionDenied))
                }
            }
        }
    }

    private static func requestAddOnlyAuthorization(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            completion(.success(()))
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited {
                    completion(.success(()))
                } else {
                    completion(.failure(PhotoLibrarySaveError.permissionDenied))
                }
            }
        case .denied, .restricted:
            completion(.failure(PhotoLibrarySaveError.permissionDenied))
        @unknown default:
            completion(.failure(PhotoLibrarySaveError.permissionDenied))
        }
    }
}
