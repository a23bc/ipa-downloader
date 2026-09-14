import Foundation

/// Represents an App Store application returned by the search / lookup API.
struct AppItem: Identifiable, Hashable, Decodable {
    let trackId: Int64
    let trackName: String
    let bundleId: String
    let sellerName: String?
    let version: String?
    let price: Double?
    let formattedPrice: String?
    let artworkUrl512: String?
    let artworkUrl100: String?
    let artworkUrl60: String?
    let primaryGenreName: String?
    let trackViewUrl: String?
    let minimumOsVersion: String?
    let fileSizeBytes: Int64?
    let releaseNotes: String?
    let description: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let isGameCenterEnabled: Bool?

    var id: Int64 { trackId }

    enum CodingKeys: String, CodingKey {
        case trackId, trackName, bundleId = "bundleId"
        case sellerName, version, price, formattedPrice
        case artworkUrl512, artworkUrl100, artworkUrl60
        case primaryGenreName, trackViewUrl, minimumOsVersion
        case fileSizeBytes, releaseNotes, description
        case averageUserRating, userRatingCount, isGameCenterEnabled
    }

    /// Convenience accessor for the best-resolution icon URL.
    var iconURL: URL? {
        let preferred = artworkUrl512 ?? artworkUrl100 ?? artworkUrl60
        return preferred.flatMap(URL.init(string:))
    }

    /// File size formatted for display, e.g. "1.2 GB".
    var displaySize: String? {
        guard let bytes = fileSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// True if the app is free (price == 0 or nil and formattedPrice is "Free").
    var isFree: Bool {
        if let p = price, p == 0 { return true }
        if let f = formattedPrice?.lowercased(), f == "free" { return true }
        return price == nil && formattedPrice == nil
    }
}
