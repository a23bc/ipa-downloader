import Foundation

/// Search / lookup service for the iTunes Store public API.
@MainActor
final class SearchService: ObservableObject {
    @Published private(set) var results: [AppItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let http = HTTPClient.shared

    func search(term: String, country: String) async {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let resp = try await http.send(SearchEndpoint(term: term, country: country, limit: 50))
            results = resp.results
        } catch {
            self.error = error.localizedDescription
            results = []
        }
    }

    func lookup(appId: Int64, country: String) async throws -> AppItem? {
        let resp = try await http.send(LookupEndpoint(id: appId, country: country))
        return resp.results.first
    }

    func lookup(bundleId: String, country: String) async throws -> AppItem? {
        let resp = try await http.send(LookupEndpoint(bundleId: bundleId, country: country))
        return resp.results.first
    }

    /// Reset the search state (called from the UI when the user clears the query).
    func clear() {
        results = []
        error = nil
        isLoading = false
    }
}
