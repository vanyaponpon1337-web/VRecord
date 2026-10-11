import Foundation
import Photos

/// Requests only add-only access. A temporary resource is removed once Photos
/// has copied it, or once a terminal permission/save failure has been reported.
final class MediaLibraryManager {
    enum LibraryError: LocalizedError {
        case permissionDenied
        case duplicateSave
        case busy
        case missingFile
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Photos add-only permission is required to save media."
            case .duplicateSave: return "This media resource is already being saved or was saved."
            case .busy: return "Four media resources are already waiting for Photos."
            case .missingFile: return "The completed media file is missing."
            case .saveFailed: return "Photos could not save the completed media file."
            }
        }
    }

    private enum ResourceKind {
        case photo
        case video

        var photoKitType: PHAssetResourceType {
            switch self {
            case .photo: return .photo
            case .video: return .video
            }
        }
    }

    private let queue = DispatchQueue(label: "com.vrecord.photos", qos: .utility)
    private var pendingURLs = Set<URL>()
    private var completedURLs: [URL] = []
    private var authorizationWaiters: [(Bool) -> Void] = []
    private var isRequestingAuthorization = false

    func savePhoto(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        save(url: url, kind: .photo, completion: completion)
    }

    func saveVideo(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        save(url: url, kind: .video, completion: completion)
    }

    private func save(url: URL, kind: ResourceKind, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let fileURL = url.standardizedFileURL
            guard !pendingURLs.contains(fileURL), !completedURLs.contains(fileURL) else {
                deliver(completion, result: .failure(LibraryError.duplicateSave))
                return
            }
            guard pendingURLs.count < 4 else {
                MediaFileStore.remove(fileURL)
                deliver(completion, result: .failure(LibraryError.busy))
                return
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                deliver(completion, result: .failure(LibraryError.missingFile))
                return
            }
            pendingURLs.insert(fileURL)
            authorize { [self] allowed in
                guard allowed else {
                    settle(fileURL, completion: completion, result: .failure(LibraryError.permissionDenied))
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    // Keep file ownership explicit: PhotoKit copies it before the
                    // completion handler, then settle removes our temporary file.
                    options.shouldMoveFile = false
                    options.originalFilename = "VRecord-\(fileURL.lastPathComponent)"
                    request.addResource(with: kind.photoKitType, fileURL: fileURL, options: options)
                } completionHandler: { [self] success, error in
                    queue.async { [self] in
                        let result: Result<Void, Error> = success ? .success(()) : .failure(error ?? LibraryError.saveFailed)
                        settle(fileURL, completion: completion, result: result)
                    }
                }
            }
        }
    }

    /// Always called on queue, including its callbacks; requests are coalesced so
    /// two hands cannot produce overlapping authorization prompts.
    private func authorize(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            authorizationWaiters.append(completion)
            guard !isRequestingAuthorization else { return }
            isRequestingAuthorization = true
            DispatchQueue.main.async { [self] in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] newStatus in
                    queue.async { [self] in
                        isRequestingAuthorization = false
                        let waiters = authorizationWaiters
                        authorizationWaiters.removeAll(keepingCapacity: true)
                        let allowed = newStatus == .authorized || newStatus == .limited
                        waiters.forEach { $0(allowed) }
                    }
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func settle(_ url: URL, completion: @escaping (Result<Void, Error>) -> Void, result: Result<Void, Error>) {
        pendingURLs.remove(url)
        if case .success = result {
            completedURLs.append(url)
            if completedURLs.count > 64 { completedURLs.removeFirst(completedURLs.count - 64) }
        }
        MediaFileStore.remove(url)
        deliver(completion, result: result)
    }

    private func deliver(_ completion: @escaping (Result<Void, Error>) -> Void, result: Result<Void, Error>) {
        DispatchQueue.main.async { completion(result) }
    }
}
