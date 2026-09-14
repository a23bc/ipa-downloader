import Foundation

/// App Store lookup/search endpoint — used to find apps by bundle id or keyword.
///
/// This is the public iTunes Search API; it does not require authentication.
struct SearchEndpoint: Endpoint {
    let term: String
    let country: String
    let entity: String = "software"
    let limit: Int

    init(term: String, country: String, limit: Int = 50) {
        self.term = term
        self.country = country
        self.limit = limit
    }

    var url: URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return components.url!
    }

    struct Response: Decodable {
        let resultCount: Int
        let results: [AppItem]
    }
}

/// Lookup endpoint — used to fetch details for a specific trackId or bundleId.
struct LookupEndpoint: Endpoint {
    let id: Int64?
    let bundleId: String?
    let country: String

    init(id: Int64, country: String) {
        self.id = id
        self.bundleId = nil
        self.country = country
    }

    init(bundleId: String, country: String) {
        self.id = nil
        self.bundleId = bundleId
        self.country = country
    }

    var url: URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "country", value: country)]
        if let id { items.append(URLQueryItem(name: "id", value: String(id))) }
        if let bundleId { items.append(URLQueryItem(name: "bundleId", value: bundleId)) }
        components.queryItems = items
        return components.url!
    }

    struct Response: Decodable {
        let resultCount: Int
        let results: [AppItem]
    }
}
