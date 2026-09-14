import Foundation

/// Apple's known storefront identifiers — partial list of the most-used regions.
/// Used both for the `Storefront` header on lookup requests and for routing
/// the search/purchase flows.
enum Storefront: String, CaseIterable, Codable {
    case US = "143441-1,29"
    case CN = "143465-19,29"
    case HK = "143463-9,31"
    case TW = "143470-10,31"
    case JP = "143462-9,31"
    case KR = "143466-13,31"
    case GB = "143444-2,31"
    case DE = "143443-4,31"
    case FR = "143442-3,31"
    case AU = "143460-9,31"
    case CA = "143455-6,31"
    case SG = "143464-9,31"
    case IN = "143467-13,31"
    case RU = "143469-13,31"
    case BR = "143503-13,31"

    var countryCode: String {
        switch self {
        case .US: return "US"
        case .CN: return "CN"
        case .HK: return "HK"
        case .TW: return "TW"
        case .JP: return "JP"
        case .KR: return "KR"
        case .GB: return "GB"
        case .DE: return "DE"
        case .FR: return "FR"
        case .AU: return "AU"
        case .CA: return "CA"
        case .SG: return "SG"
        case .IN: return "IN"
        case .RU: return "RU"
        case .BR: return "BR"
        }
    }

    var displayName: String {
        switch self {
        case .US: return "United States"
        case .CN: return "China Mainland"
        case .HK: return "Hong Kong"
        case .TW: return "Taiwan"
        case .JP: return "Japan"
        case .KR: return "Korea"
        case .GB: return "United Kingdom"
        case .DE: return "Germany"
        case .FR: return "France"
        case .AU: return "Australia"
        case .CA: return "Canada"
        case .SG: return "Singapore"
        case .IN: return "India"
        case .RU: return "Russia"
        case .BR: return "Brazil"
        }
    }

    /// Resolve a storefront by country code.
    static func from(countryCode: String) -> Storefront? {
        Storefront.allCases.first { $0.countryCode == countryCode.uppercased() }
    }
}
