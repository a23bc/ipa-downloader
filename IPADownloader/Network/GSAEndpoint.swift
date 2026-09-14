import Foundation

/// Apple's GSA (Grand Slam Authentication) endpoints.
///
/// See https://github.com/Dadoum/anisette-v3-server for the broader flow.
/// All these endpoints expect the following device-specific headers, which
/// are injected by `AnisetteHeadersProvider`:
///   - X-Apple-I-MD
///   - X-Apple-I-MD-M
///   - X-Apple-I-MD-RINFO
///   - X-Mme-Device-Id
///   - X-Apple-I-Client-Time
///   - User-Agent: Xcode
enum GSAEndpoint {
    case initSRP(appleId: String, deviceID: String)
    case completeSRP(appleId: String, deviceID: String, body: Data)
    case authenticate(appleId: String, deviceID: String, body: Data)
    case submit2FACode(scnt: String, code: String, deviceID: String)
    case trust2FADevice(scnt: String, deviceID: String, phoneNumber: String?)
    case validateToken(dsPrsID: String, mid: String)
}

extension GSAEndpoint {
    static let baseURL = URL(string: "https://gsa.apple.com")!

    func urlRequest(headers: [String: String], body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: path)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private var path: URL {
        switch self {
        case .initSRP:       return GSAEndpoint.baseURL.appendingPathComponent("grandslam/GsService2")
        case .completeSRP:   return GSAEndpoint.baseURL.appendingPathComponent("grandslam/GsService2")
        case .authenticate:   return GSAEndpoint.baseURL.appendingPathComponent("grandslam/GsService2")
        case .submit2FACode: return URL(string: "https://gsa.apple.com/auth/verify/trusteddevice/securitycode")!
        case .trust2FADevice: return URL(string: "https://gsa.apple.com/auth/verify/phone")!
        case .validateToken: return URL(string: "https://gsa.apple.com/auth/validate")!
        }
    }

    private var method: String {
        switch self {
        case .initSRP, .completeSRP, .authenticate, .submit2FACode, .trust2FADevice, .validateToken:
            return "POST"
        }
    }
}
