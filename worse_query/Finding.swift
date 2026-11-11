import Foundation

struct Finding: Codable, Identifiable {
    let id: UUID
    let bundleId: String
    let type: FindingType
    let file: String
    let key: String
    let value: String
    let severity: Severity

    enum FindingType: String, Codable {
        case sessionCookie = "session_cookie"
        case jwt           = "jwt_token"
        case plistToken    = "plist_token"
        case plistPII      = "plist_pii"
    }

    enum Severity: String, Codable, Comparable {
        case critical = "CRITICAL"
        case high     = "HIGH"
        case medium   = "MEDIUM"
        case low      = "LOW"

        private var rank: Int {
            switch self {
            case .critical: return 3
            case .high:     return 2
            case .medium:   return 1
            case .low:      return 0
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }
}
