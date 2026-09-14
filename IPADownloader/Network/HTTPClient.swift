import Foundation

/// A single HTTP request described declaratively.
/// Conforming types provide the URL, method, headers and body; the `HTTPClient`
/// takes care of execution, retries and parsing.
protocol Endpoint {
    associatedtype Response: Decodable

    var url: URL { get }
    var method: String { get }
    var headers: [String: String] { get }
    var body: Data? { get }
    var timeout: TimeInterval { get }
}

extension Endpoint {
    var method: String { "GET" }
    var headers: [String: String] { [:] }
    var body: Data? { nil }
    var timeout: TimeInterval { 30 }
}

/// Generic HTTP client wrapping `URLSession` with logging and basic retry.
final class HTTPClient {
    static let shared = HTTPClient()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum HTTPError: Error, LocalizedError {
        case invalidResponse
        case status(Int, Data)
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from server"
            case .status(let code, let body):
                let bodyString = String(data: body, encoding: .utf8)?.prefix(500) ?? ""
                return "HTTP \(code): \(bodyString)"
            case .decoding(let err): return "Decoding error: \(err)"
            case .transport(let err): return "Network error: \(err)"
            }
        }
    }

    @discardableResult
    func send<E: Endpoint>(_ endpoint: E) async throws -> E.Response {
        var req = URLRequest(url: endpoint.url)
        req.httpMethod = endpoint.method
        req.timeoutInterval = endpoint.timeout
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = endpoint.body
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            if !(200..<300).contains(http.statusCode) {
                throw HTTPError.status(http.statusCode, data)
            }
            do {
                return try JSONDecoder().decode(E.Response.self, from: data)
            } catch {
                // Some endpoints return plain 200 with no body; allow Response == EmptyResponse.
                if E.Response.self == EmptyResponse.self {
                    return EmptyResponse() as! E.Response
                }
                throw HTTPError.decoding(error)
            }
        } catch let err as HTTPError {
            throw err
        } catch {
            throw HTTPError.transport(error)
        }
    }

    /// Raw data download for binary endpoints (IPA chunks, etc.).
    func sendRaw(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }
        return (data, http)
    }
}

/// Convenience type for endpoints with empty response body.
struct EmptyResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws { self.init() }
}
