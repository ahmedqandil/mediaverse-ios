import Foundation

public struct MatrixNativeMentionTarget:
    Identifiable,
    Equatable,
    Hashable,
    Sendable
{
    public var id: String { userID }
    public let userID: String
    public let displayName: String

    public init(userID: String, displayName: String) {
        self.userID = userID
        self.displayName = displayName
    }

    public var composerLabel: String {
        "@\(displayName.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public enum MatrixNativeMentionComposer {
    public static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let preceding = text[text.index(before: at)]
            guard preceding.isWhitespace || preceding.isNewline else { return nil }
        }
        let queryStart = text.index(after: at)
        let suffix = text[queryStart...]
        guard !suffix.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }
        return String(suffix)
    }

    public static func inserting(
        _ target: MatrixNativeMentionTarget,
        into text: String
    ) -> String {
        guard let at = text.lastIndex(of: "@"),
              query(in: text) != nil else {
            return text + (text.last?.isWhitespace == true ? "" : " ")
                + target.composerLabel + " "
        }
        return String(text[..<at]) + target.composerLabel + " "
    }

    public static func activeTargets(
        in text: String,
        selected: [MatrixNativeMentionTarget]
    ) -> [MatrixNativeMentionTarget] {
        var unique: [String: MatrixNativeMentionTarget] = [:]
        for target in selected {
            unique[target.userID] = target
        }
        return unique.values
            .filter { text.localizedCaseInsensitiveContains($0.composerLabel) }
            .sorted { $0.userID < $1.userID }
    }

    public static func formattedHTML(
        body: String,
        mentions: [MatrixNativeMentionTarget]
    ) -> String? {
        guard !mentions.isEmpty else { return nil }
        var html = escapeHTML(body)
        for target in mentions.sorted(by: {
            $0.composerLabel.count > $1.composerLabel.count
        }) {
            let escapedLabel = escapeHTML(target.composerLabel)
            let href = escapeHTML("https://matrix.to/#/\(target.userID)")
            html = html.replacingOccurrences(
                of: escapedLabel,
                with: "<a href=\"\(href)\">\(escapedLabel)</a>",
                options: [.caseInsensitive]
            )
        }
        return html.replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Product vocabulary layered over standard `m.reaction` relations.
///
/// The stable Matrix reaction key is versioned so future clients can evolve
/// presentation without rewriting Matrix history. SF Symbols are presentation
/// metadata only and never become protocol payloads.
public struct MatrixNativeEnergyOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let systemImage: String

    public init(id: String, label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }

    public static let all: [Self] = [
        .init(id: "com.westreem.energy.v1:HITS", label: "Hits", systemImage: "waveform.path"),
        .init(id: "com.westreem.energy.v1:INSPIRED", label: "Inspired", systemImage: "star.fill"),
        .init(id: "com.westreem.energy.v1:REAL", label: "Real", systemImage: "lightbulb.fill"),
        .init(id: "com.westreem.energy.v1:DEEP", label: "Deep", systemImage: "brain.head.profile"),
        .init(id: "com.westreem.energy.v1:CHILL", label: "Chill", systemImage: "face.smiling"),
        .init(id: "com.westreem.energy.v1:CLUTCH", label: "Clutch", systemImage: "bolt.fill"),
    ]
}

public enum MatrixNativeWaveAction: String, CaseIterable, Sendable {
    case reply
    case addEnergy
    case edit
    case redact
    case report
    case pin
}

public enum MatrixNativeWaveActionBlockReason: Equatable, Sendable {
    case rolloutDisabled
    case sessionUnavailable
    case roomNotJoined
    case ignoredSender
    case missingRemoteEvent
    case unableToDecrypt
    case insufficientPower
    case notEventAuthor
    case encryptedReportUnsupported
}

/// Fail-closed action eligibility shared by the repository and UI.
public enum MatrixNativeWaveActionPolicy {
    public static let normativeSource =
        "User strongest-model Matrix-native Vibes prompt (precedence 1)"
    public static let maximumMessageCharacters = 4_000
    public static let maximumReportCharacters = 1_000
    public static let replyPreviewLimit = 2

    public static func permits(
        _ action: MatrixNativeWaveAction,
        roomIsJoined: Bool,
        senderIsIgnored: Bool,
        isRemoteEvent: Bool,
        isOwnEvent: Bool,
        isUnableToDecrypt: Bool,
        roomIsEncrypted: Bool,
        maySendMessage: Bool,
        maySendReaction: Bool,
        mayRedactOwn: Bool,
        mayRedactOther: Bool,
        mayPin: Bool
    ) -> Bool {
        guard roomIsJoined, !senderIsIgnored, !isUnableToDecrypt else {
            return false
        }
        switch action {
        case .reply:
            return isRemoteEvent && maySendMessage
        case .addEnergy:
            return maySendReaction
        case .edit:
            return isOwnEvent && maySendMessage
        case .redact:
            return isOwnEvent ? mayRedactOwn : mayRedactOther
        case .report:
            // The bound Matrix Rust SDK report API forwards only event ID and
            // reason. It cannot attach decrypted evidence, so an encrypted
            // event report would be misleading to moderators.
            return isRemoteEvent && !isOwnEvent && !roomIsEncrypted
        case .pin:
            return isRemoteEvent && mayPin
        }
    }

    public static func normalizedMessage(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumMessageCharacters))
    }

    public static func normalizedReportReason(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumReportCharacters))
    }

    public static func isSupportedEnergyKey(_ key: String) -> Bool {
        MatrixNativeEnergyOption.all.contains { $0.id == key }
    }
}

enum MatrixNativeWaveAccess: String, CaseIterable, Equatable, Sendable {
    case publicRoom
    case inviteOnly
    case requestToJoin
}

enum MatrixNativeWaveHistory: String, CaseIterable, Equatable, Sendable {
    case invited
    case joined
    case shared
    case worldReadable
}

enum MatrixNativeWaveNotificationMode: String, CaseIterable, Equatable, Sendable {
    case allMessages
    case mentionsOnly
    case muted
}

enum MatrixNativeWaveMemberRole: String, CaseIterable, Equatable, Sendable {
    case creator
    case administrator
    case moderator
    case member
}

enum MatrixNativeWaveMemberState: String, Equatable, Sendable {
    case joined
    case invited
    case banned
    case requested
}

enum MatrixNativeWaveModerationAction: Equatable, Sendable {
    case kick
    case ban
    case unban
}

enum MatrixNativeWaveManagementContract {
    static let normativeSource =
        "User strongest-model Matrix-native Vibes prompt (precedence 1)"
    static let maximumNameLength = 255
    static let maximumTopicLength = 4_000
    static let minimumSearchLength = 2
    static let maximumSearchLength = 128

    static func normalizedProfile(
        name: String,
        topic: String
    ) -> (name: String, topic: String)? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.count <= maximumNameLength,
              normalizedTopic.count <= maximumTopicLength
        else {
            return nil
        }
        return (normalizedName, normalizedTopic)
    }

    static func normalizedSearch(_ query: String) -> String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= minimumSearchLength,
              value.count <= maximumSearchLength
        else {
            return nil
        }
        return value
    }

    static func mayManage(
        isCurrentUser: Bool,
        isService: Bool,
        role: MatrixNativeWaveMemberRole
    ) -> Bool {
        !isCurrentUser && !isService && role != .creator
    }

    static func powerLevel(_ role: MatrixNativeWaveMemberRole) -> Int64? {
        switch role {
        case .creator: nil
        case .administrator: 100
        case .moderator: 50
        case .member: 0
        }
    }
}
