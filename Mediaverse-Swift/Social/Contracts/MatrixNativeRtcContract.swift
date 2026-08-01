import Foundation

public enum MatrixNativeRtcIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case audio
    case video
}

public enum MatrixNativeRtcMediaProvider: String, Codable, Sendable, CaseIterable {
    case livekit = "LIVEKIT"
    case cloudflareRealtime = "CLOUDFLARE_REALTIME"
}

public enum MatrixNativeRtcMediaSecurity: String, Codable, Sendable {
    case standardWebRTC = "DTLS_SRTP"
}

public enum MatrixNativeRtcContract {
    public static let normativeSource =
        "User strongest-model Matrix-native Vibes prompt (precedence 1)"
    public static let authority = "MATRIX"
    public static let mediaTransport = "EXISTING_LIVEKIT"
    public static let productionMediaProvider = MatrixNativeRtcMediaProvider.livekit
    public static let membershipEventType = "org.matrix.msc3401.call.member"
    public static let application = "m.call"
    public static let roomScope = "m.room"
    public static let membershipLifetimeMilliseconds: Int64 =
        4 * 60 * 60 * 1_000
    public static let membershipRefreshMilliseconds: Int64 =
        3 * 60 * 60 * 1_000
    public static let permitsNewInfrastructure = false
    public static let applicationMediaEncryptionEnabled = false
    public static let swiftBindingsExportMatrixRtcMediaKeys = false
    /// Migration groundwork only. Cloudflare cannot receive any cohort while
    /// this remains false, and provider selection is fixed when a call starts.
    public static let directCloudflareRealtimeEnabled = false

    public static func acceptsProductionConnectionProvider(_ provider: String) -> Bool {
        provider.caseInsensitiveCompare("livekit") == .orderedSame
    }
}
