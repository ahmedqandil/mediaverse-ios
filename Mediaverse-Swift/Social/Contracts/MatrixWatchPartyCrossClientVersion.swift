import Foundation

/// Version/host rules shared by Web-authored and Swift-authored Watch Party
/// state. Legacy iOS payloads have neither `host` nor `sequence`, so both
/// remain backwards compatible while newer Web handoffs stay monotonic.
public enum MatrixWatchPartyCrossClientVersion {
    public static func controllingUserID(
        host: String?,
        startedBy: String?
    ) -> String? {
        let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedHost, !normalizedHost.isEmpty { return normalizedHost }
        let normalizedStarter = startedBy?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedStarter.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func nextSequence(after current: Int64?) -> Int64? {
        let value = max(0, current ?? 0)
        guard value < Int64.max else { return nil }
        return value + 1
    }

    public static func playbackEpoch(nowMilliseconds: Int64, sequence: Int64) -> String {
        "swift_\(max(0, nowMilliseconds))_\(max(0, sequence))"
    }
}
