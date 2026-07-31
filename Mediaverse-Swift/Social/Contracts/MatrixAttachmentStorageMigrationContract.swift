import Foundation

/// Client invariants for moving Synapse's Matrix media storage to a
/// Cloudflare-backed provider. Storage is an infrastructure concern: clients
/// continue to speak the standard Matrix media protocol through MatrixRustSDK.
public enum MatrixAttachmentStorageMigrationContract {
    public enum AttachmentKind: String, CaseIterable, Sendable {
        case image
        case video
        case audio
        case voice
        case file
        case gallery
        case sticker
    }

    public enum LifecycleOwner: Equatable, Sendable {
        case matrixRustSDK
    }

    public static let uploadProgressOwner: LifecycleOwner = .matrixRustSDK
    public static let retryOwner: LifecycleOwner = .matrixRustSDK

    /// Phase one must never issue an R2/Cloudflare upload ticket to a client.
    public static let permitsDirectCloudflareUpload = false

    /// Compression/transcoding changes message bytes and encrypted-file
    /// metadata, so it remains out of scope until separately designed and
    /// proven interoperable for both clear and encrypted rooms.
    public static let permitsClientTranscoding = false

    public static func acceptsPersistedMediaURL(_ value: String) -> Bool {
        guard value.hasPrefix("mxc://"), value.utf8.count <= 2_048 else {
            return false
        }
        let identity = value.dropFirst("mxc://".count)
        guard let separator = identity.firstIndex(of: "/") else { return false }
        let server = identity[..<separator]
        let mediaID = identity[identity.index(after: separator)...]
        return !server.isEmpty
            && !mediaID.isEmpty
            && !value.contains(where: \.isWhitespace)
            && !mediaID.contains("/")
            && !value.contains("?")
            && !value.contains("#")
    }

    public static func requiresSDKAttachmentAPI(for kind: AttachmentKind) -> Bool {
        AttachmentKind.allCases.contains(kind)
    }
}
