import Foundation

/// iTunes Store purchase / download endpoints used by `ipatool` after the user
/// has authenticated via GSA.
///
/// The `purchase` endpoint issues a signed download manifest for the app; the
/// `download` endpoint is the actual MPEG-DASH-packaged .ipa package split
/// into encrypted chunks. We follow ipatool's flow:
///
/// 1. POST to `/WebObjects/MZFinance.woa/wa/buyProduct`
///    with XML body containing the app adamId / pricing parameters.
/// 2. Receive XML response with signed manifest (key, salt, signatures).
/// 3. Parse chunk list from the manifest (key + sig + free trial sig).
/// 4. Download each chunk via the delivery URL.
/// 5. Decrypt each chunk with AES-128-CBC + HMAC-SHA1 verify, then concatenate.
/// 6. Unzip the resulting .zip → .ipa file.

struct BuyProductEndpoint: Endpoint {
    static let baseURL = URL(string: "https://p25-buy.itunes.apple.com")!

    let adamId: Int64
    let appVersion: String?
    let storeFrontId: String         // e.g. "143441-1,29"
    let appleIdAccount: AppleAccount // for guid & dsid
    let price: Double?

    var url: URL { Self.baseURL.appendingPathComponent("WebObjects/MZFinance.woa/wa/buyProduct") }
    var method: String { "POST" }
    var timeout: TimeInterval { 60 }

    var headers: [String: String] {
        [
            "Content-Type": "application/x-apple-plist",
            "X-Apple-Store-Front": storeFrontId,
            "X-Apple-Tz": "28800",
            "User-Agent": "Configurator/2.0 (Macintosh; OS X 11.0; 16G29) AppleWebKit/1661.4.0.1.10",
            "Accept": "*/*",
            "Accept-Language": "en-us",
            "iCloud-DSID": appleIdAccount.dsid ?? ""
        ]
    }

    var body: Data? {
        let versionStr = appVersion ?? ""
        let priceStr: String
        if let price = price, price > 0 {
            priceStr = "<price>\(Int(price * 100))</price>"
        } else {
            priceStr = "<price>0</price>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>appExtVId</key>
            <dict>
                <key>appVId</key><string>\(versionStr)</string>
                <key>bid</key><string>com.apple.Configurator</string>
                <key> HVID </key><string>\(appleIdAccount.guid ?? "")</string>
            </dict>
            <key>hasBeenAuthToken</key>
            <string>PFMxADEAAQBYUGZtTzFLVFBNT2I1MWlzNGRSTEpvcjU4WDZ0Yzg3Z3NXZz09AAAA</string>
            <key>buyProductParameterList</key>
            <dict>
                <key>clientApplicationName</key><string>Configurator</string>
                <key>appleId</key><string>\(appleIdAccount.appleId)</string>
                <key>buy</key><string>\(adamId)</string>
                <key>guid</key><string>\(appleIdAccount.guid ?? "")</string>
                \(priceStr)
                <key>appExtVrsId</key><string>\(versionStr)</string>
                <key>pricingParameters</key><string>STDQ</string>
            </dict>
        </dict>
        </plist>
        """
        return xml.data(using: .utf8)
    }

    /// The buyProduct response is a plist; we decode only the fields we need.
    struct Response: Decodable {
        let status: Int
        let isPurchased: Bool?
        let adamId: String?
        let version: String?
        let downloadQueue: DownloadQueue?

        enum CodingKeys: String, CodingKey {
            case status
            case isPurchased
            case adamId
            case version
            case downloadQueue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = (try? c.decode(Int.self, forKey: .status)) ?? 0
            isPurchased = try? c.decode(Bool.self, forKey: .isPurchased)
            adamId = try? c.decode(String.self, forKey: .adamId)
            version = try? c.decode(String.self, forKey: .version)
            downloadQueue = try? c.decode(DownloadQueue.self, forKey: .downloadQueue)
        }

        init(status: Int = 0, downloadQueue: DownloadQueue? = nil) {
            self.status = status
            self.downloadQueue = downloadQueue
            self.isPurchased = nil
            self.adamId = nil
            self.version = nil
        }
    }

    struct DownloadQueue: Decodable {
        let songList: [Song]?
        let key: String?
        let salt: String?
        let signer: String?
        let signature: String?
        let freeTrialSig: String?
    }

    struct Song: Decodable {
        let adamId: String
        let metadata: SongMetadata?
        let assets: [Asset]?
        let version: String?
    }

    struct SongMetadata: Decodable {
        let bundleId: String?
        let purchaseDate: String?
        let appIdextVrsId: String?
        let copyrights: String?
    }

    struct Asset: Decodable {
        let url: String
        let flavor: String?
        let size: Int64?
        let hash: String?
        let key: String?
        let decryptionKey: String?
    }
}

/// iTunes download chunk endpoint — a Range request returning encrypted .dmedia bytes.
struct DownloadChunkEndpoint {
    let url: URL
    let range: (start: Int64, end: Int64)

    var urlRequest: URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        req.setValue("application/x-apple-plist", forHTTPHeaderField: "Accept")
        return req
    }
}
