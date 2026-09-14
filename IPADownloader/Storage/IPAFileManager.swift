import Foundation

/// Filesystem helpers for downloaded .ipa storage.
/// Files are written to the app's Documents directory (visible in the Files app).
enum IPAFileManager {
    /// Root directory where downloaded IPAs are stored.
    static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Temp directory for in-progress downloads.
    static var tempDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IPADownloader", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Build the destination file URL for a given app.
    static func fileURL(for app: AppItem) -> URL {
        let safeName = app.trackName.replacingOccurrences(of: "/", with: "_")
        let safeVersion = app.version?.replacingOccurrences(of: "/", with: "_") ?? "unknown"
        return downloadsDirectory.appendingPathComponent("\(safeName) \(safeVersion) (\(app.trackId)).ipa")
    }

    /// List all .ipa files in the downloads directory.
    static func listDownloadedIPA() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: downloadsDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.filter { $0.pathExtension == "ipa" }
                   .sorted { (a, b) in
                       let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                       let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                       return aDate > bDate
                   }
    }

    /// Delete a file by URL.
    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Get file size in bytes (0 if not found).
    static func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
