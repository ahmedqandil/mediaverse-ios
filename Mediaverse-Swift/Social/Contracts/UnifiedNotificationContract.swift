import Foundation

/// Versioned presentation contract. It merges two authorities without copying
/// Matrix social notifications into Westreem-owned notification records.
public struct UnifiedNotificationFeedV1: Decodable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let items: [UnifiedNotificationItem]
    public let sources: UnifiedNotificationSources

    public var isSupportedVersion: Bool {
        enabled && version == 1
    }
}

public struct UnifiedNotificationSources: Decodable, Sendable {
    public let westreem: UnifiedNotificationSourceState
    public let matrix: UnifiedNotificationSourceState
}

public struct UnifiedNotificationSourceState: Decodable, Sendable {
    public let authority: UnifiedNotificationAuthority
    public let readAuthority: UnifiedNotificationReadAuthority
    public let status: UnifiedNotificationSourceStatus
    public let storesContentMetadata: Bool?
}

public enum UnifiedNotificationAuthority: String, Decodable, Sendable {
    case westreem = "WESTREEM"
    case matrix = "MATRIX"
}

public enum UnifiedNotificationReadAuthority: String, Decodable, Sendable {
    case westreemAPI = "WESTREEM_API"
    case matrixReceipt = "MATRIX_RECEIPT"
}

public enum UnifiedNotificationSourceStatus: String, Decodable, Sendable {
    case ready = "READY"
    case disabled = "DISABLED"
    case clientRequired = "CLIENT_REQUIRED"
    case clientUnavailable = "CLIENT_UNAVAILABLE"
}

public enum UnifiedNotificationCategory: String, Decodable, Sendable {
    case atmo = "ATMO"
    case westreemProduct = "WESTREEM_PRODUCT"
    case matrixVibe = "MATRIX_VIBE"
}

public struct UnifiedNotificationItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let source: UnifiedNotificationAuthority
    public let canonicalId: String
    public let category: UnifiedNotificationCategory
    public let type: String
    public let title: String
    public let message: String
    public let read: Bool
    public let createdAt: String
    public let linkUrl: String?
    public let imageUrl: String?
    public let readAuthority: UnifiedNotificationReadAuthority
    public let matrixRoomId: String?
    public let matrixEventId: String?
}

/// Stable deterministic merge used once the Matrix Rust SDK notification
/// adapter is available. Dedupe is scoped by authority.
public enum UnifiedNotificationMerge {
    public static func merge(
        _ sources: [[UnifiedNotificationItem]]
    ) -> [UnifiedNotificationItem] {
        var unique: [String: UnifiedNotificationItem] = [:]
        for item in sources.flatMap({ $0 }) {
            let key = "\(item.source.rawValue):\(item.canonicalId)"
            guard let previous = unique[key] else {
                unique[key] = item
                continue
            }
            if sortDate(item.createdAt) > sortDate(previous.createdAt)
                || (
                    sortDate(item.createdAt) == sortDate(previous.createdAt)
                    && item.id < previous.id
                ) {
                unique[key] = item
            }
        }
        return unique.values.sorted { left, right in
            let leftDate = sortDate(left.createdAt)
            let rightDate = sortDate(right.createdAt)
            if leftDate != rightDate { return leftDate > rightDate }
            if left.source.rawValue != right.source.rawValue {
                return left.source.rawValue < right.source.rawValue
            }
            return left.canonicalId < right.canonicalId
        }
    }

    private static func sortDate(_ value: String) -> TimeInterval {
        ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? 0
    }
}

/// The app must not claim a unified Matrix inbox until the Rust SDK adapter can
/// read notifications and write Matrix receipts. This is deliberately honest.
public enum UnifiedNotificationSwiftCapability {
    public static let contractVersion = 1
    public static let matrixNotificationAdapterAvailable = true
    public static let matrixReadAuthority = "MatrixRustSDK receipt"
    public static let permitsWestreemMatrixNotificationCopies = false
    public static let presentationCacheAuthority = "MatrixRustSDK sync and unread room state"
    public static let apnsTransportAuthority = "Existing Westreem APNs registration"
}

/// Pure validation rules shared by the native UI and executable contract
/// tests. Westreem search discovers a canonical user; Matrix remains the only
/// authority that discovers or creates the corresponding direct room.
public enum MatrixDirectMessageContract {
    public static let roomAuthority = "MatrixRustSDK"
    public static let requiresEncryptedRoom = true
    public static let requiresDirectFlag = true
    public static let requiresMatrixIgnoredUserCheck = true
    public static let permitsUnencryptedExistingRoom = false
    public static let permitsLegacyMessageAPI = false

    public static func normalizedSearchQuery(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return nil }
        return String(normalized.prefix(80))
    }

    public static func mayCreate(
        currentMatrixUserID: String,
        targetMatrixUserID: String,
        ignoredMatrixUserIDs: Set<String> = []
    ) -> Bool {
        let current = currentMatrixUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetMatrixUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !target.isEmpty, current != target else { return false }
        guard !ignoredMatrixUserIDs.contains(target) else { return false }
        return isCanonicalWestreemPeer(target)
    }

    public static func mayUseExistingRoom(isEncrypted: Bool) -> Bool {
        isEncrypted || permitsUnencryptedExistingRoom
    }

    public static func mayPresentExistingRoom(
        isEncrypted: Bool,
        isDirect: Bool,
        peerMatrixUserID: String
    ) -> Bool {
        isDirect
            && mayUseExistingRoom(isEncrypted: isEncrypted)
            && isCanonicalWestreemPeer(peerMatrixUserID)
    }

    public static func isCanonicalWestreemPeer(_ matrixUserID: String) -> Bool {
        let parts = matrixUserID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == Substring(MatrixCanonicalIdentity.serverName) else {
            return false
        }
        let localpart = String(parts[0])
        return localpart.hasPrefix("@u_") && localpart.count > 3
    }
}

/// Matrix notification entries are presentation projections only. Opening an
/// entry writes a Matrix read receipt and never mutates Westreem's notification
/// records.
public enum MatrixNotificationPresentationContract {
    public static let maximumBufferedItems = 200
    public static let maximumUnreadRoomFallbacks = 50
    public static let readAuthority = UnifiedNotificationReadAuthority.matrixReceipt
    public static let permitsServerSideContentCopies = false

    public static func canonicalID(roomID: String, eventID: String?) -> String {
        let event = eventID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(roomID)|\(event?.isEmpty == false ? event! : "unread")"
    }
}
