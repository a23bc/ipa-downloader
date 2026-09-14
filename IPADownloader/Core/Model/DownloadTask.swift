import Foundation

/// Represents a single tracked download session.
struct DownloadTask: Identifiable, Hashable {
    enum Status: String, Hashable, Codable {
        case queued
        case downloading
        case processing
        case completed
        case failed
        case paused
    }

    let id: UUID
    let appItem: AppItem
    var status: Status
    var progress: Double      // 0.0...1.0
    var bytesDownloaded: Int64
    var totalBytes: Int64
    var error: String?
    var localURL: URL?
    var startedAt: Date
    var finishedAt: Date?

    init(appItem: AppItem) {
        self.id = UUID()
        self.appItem = appItem
        self.status = .queued
        self.progress = 0
        self.bytesDownloaded = 0
        self.totalBytes = 0
        self.startedAt = Date()
    }
}
