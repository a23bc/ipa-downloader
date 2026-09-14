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
final class AnisetteHeadersProvider: ObservableObject {
    static let shared = AnisetteHeadersProvider()

    /// Override-able URL of a locally-running anisette server.
    /// Set in the Settings screen.
    var serverURL: URL? {
        get { UserDefaults.standard.url(forKey: "anisette.server.url") }
        set { UserDefaults.standard.set(newValue, forKey: "anisette.server.url") }
    }

    /// Convenience: returns the URL that `fetchHeaders()` will actually request.
    /// Used by the Settings "Test Connection" button to show the user exactly
    /// which URL the app is hitting.
    var effectiveRequestURL: URL? {
        serverURL?.appendingPathComponent("v3_anisette")
    }

    /// Fetch fresh anisette headers from the sidecar server.
    /// Returns a `[String: String]` ready to be merged into a `URLRequest`.
    func fetchHeaders() async throws -> [String: String] {
        guard let baseURL = serverURL else {
            throw AnisetteError.serverNotConfigured
        }
        let url = baseURL.appendingPathComponent("v3_anisette")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw AnisetteError.serverError(message: """
                    Response was not HTTP (got \(type(of: response))).
                    Request URL: \(url.absoluteString)
                    """)
            }
            guard http.statusCode == 200 else {
                let bodyPreview = String(data: data, encoding: .utf8)?
                    .prefix(500)
                    .replacingOccurrences(of: "\n", with: "\\n") ?? "<binary \(data.count) bytes>"
                throw AnisetteError.serverError(message: """
                    HTTP \(http.statusCode) from \(url.absoluteString)
                    Server returned: \(bodyPreview)
                    """)
            }
            guard let headers = try? JSONDecoder().decode([String: String].self, from: data) else {
                let bodyPreview = String(data: data, encoding: .utf8)?
                    .prefix(500)
                    .replacingOccurrences(of: "\n", with: "\\n") ?? "<binary \(data.count) bytes>"
                throw AnisetteError.serverError(message: """
                    Response from \(url.absoluteString) was not a JSON object.
                    Body: \(bodyPreview)
                    Expected keys: X-Apple-I-MD, X-Apple-I-MD-M, X-Mme-Device-Id
                    """)
            }
            // Inject client time + UA.
            var merged = headers
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            merged["X-Apple-I-Client-Time"] = formatter.string(from: Date())
            merged["User-Agent"] = "Xcode"
            merged["Accept"] = "*/*"
            merged["Accept-Language"] = "en-us"
            return merged
        } catch let err as AnisetteError {
            throw err
        } catch {
            // URLSession error (connection refused, timeout, DNS failure, etc.)
            throw AnisetteError.serverError(message: """
                Network error reaching \(url.absoluteString)
                Error: \(error.localizedDescription)

                Common causes:
                • URL points to 127.0.0.1 (loopback on iOS, not your PC). \
                  Use your PC's LAN IP instead, e.g. http://192.168.1.10:6969
                • Docker container didn't publish the port. Run with \
                  -p 6969:6969
                • Windows Firewall is blocking inbound connections to port 6969.
                • iOS device and PC are on different subnets.
                """)
        }
    }

    enum AnisetteError: Error, LocalizedError {
        case serverNotConfigured
        case serverError(message: String)

        var errorDescription: String? {
            switch self {
            case .serverNotConfigured:
                return "Anisette server not configured. Open Settings to set it."
            case .serverError(let msg):
                return msg
            }
        }
    }
}
