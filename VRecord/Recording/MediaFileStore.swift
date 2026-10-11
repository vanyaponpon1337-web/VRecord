import Foundation

enum MediaFileStore {
    static func makeURL(fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VRecord-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
