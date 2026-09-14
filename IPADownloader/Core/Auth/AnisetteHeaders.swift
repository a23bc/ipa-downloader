import Foundation

/// Anisette headers — Apple's device identification mechanism.
///
/// Without these headers the GSA endpoints return `X-Apple-I-MD-M` errors.
/// There are two ways to obtain them:
///
/// 1. Run a local sidecar server (https://github.com/Dadoum/anisette-v3-server)
///    on the device. Suitable for sideloaded iOS apps.
/// 2. Use `apple private apis` libraries that compute them locally using a
///    cached `adi.pb` file (only available on jailbroken devices).
///
/// For simplicity this implementation calls a local anisette HTTP server.
/// Users must run it on the same device (e.g. via iSH, or as a bundled
/// sidecar) and set its URL in `Settings`. We don't bundle the server itself.
final class AnisetteHeadersProvider {
    static let shared = AnisetteHeadersProvider()

    /// Override-able URL of a locally-running anisette server.
    /// Set in the Settings screen.
    var serverURL: URL? {
        get { UserDefaults.standard.url(forKey: "anisette.server.url") }
        set { UserDefaults.standard.set(newValue, forKey: "anisette.server.url") }
    }

    /// Fetch fresh anisette headers from the sidecar server.
    /// Returns a `[String: String]` ready to be merged into a `URLRequest`.
    func fetchHeaders() async throws -> [String: String] {
        guard let baseURL = serverURL else {
            throw AnisetteError.serverNotConfigured
        }
        let url = baseURL.appendingPathComponent("v3_anisette")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AnisetteError.serverError
        }
        guard var headers = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw AnisetteError.serverError
        }
        // Inject client time + UA.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        headers["X-Apple-I-Client-Time"] = formatter.string(from: Date())
        headers["User-Agent"] = "Xcode"
        headers["Accept"] = "*/*"
        headers["Accept-Language"] = "en-us"
        return headers
    }

    enum AnisetteError: Error, LocalizedError {
        case serverNotConfigured
        case serverError

        var errorDescription: String? {
            switch self {
            case .serverNotConfigured:
                return "Anisette server not configured. Open Settings to set it."
            case .serverError:
                return "Anisette server returned an error."
            }
        }
    }
}
