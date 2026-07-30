import Foundation

/// Governing implementation contract for Matrix-native Vibes.
///
/// The user's "strongest-model Matrix-native Vibes" prompt is normative and
/// has precedence 1 over roadmap prose, legacy social behavior, and local
/// convenience implementations.
public enum MatrixNativeGoverningContract {
    public static let normativeSource =
        "User strongest-model Matrix-native Vibes prompt (precedence 1)"
    public static let acceptanceLedger =
        "qa/matrix-native-strongest-model-acceptance.json"

    public static let matrixAuthority = "MatrixRustSDK"
    public static let legacyAuthority = "Westreem API"

    /// A hand-written Matrix Client-Server protocol implementation would
    /// create a second source of truth and is expressly forbidden.
    public static let permitsHandWrittenMatrixProtocolClient = false
}

/// Normative Swift parity surface for Matrix-native Vibes.
///
/// Keeping this as source—not prose—lets QA fail when a required capability is
/// omitted from the implementation roadmap or accidentally treated as legacy
/// Westreem social behavior.
public enum MatrixNativeCapability: String, CaseIterable, Codable, Sendable {
    case westreemOIDCSSO
    case secureTokenStorage
    case profileSynchronization
    case suspensionRevocation
    case accountDeletionLifecycle
    case spaces
    case nestedSpaces
    case publicRooms
    case privateRooms
    case roomAliases
    case membership
    case invitations
    case rolesAndPowerLevels
    case textFormatting
    case edits
    case replies
    case threads
    case reactionsAndEnergy
    case echoesAndReferences
    case mentions
    case readReceipts
    case typing
    case presence
    case unreadCounts
    case notificationSettings
    case pushRules
    case pushNotifications
    case pinning
    case roomSearch
    case roomHistory
    case moderation
    case reports
    case redactions
    case polls
    case stickers
    case multipleImageAttachments
    case fileAttachments
    case voiceMessages
    case voiceMessagePlayback
    case videoMessages
    case videoMessagePlayback
    case mediaViewer
    case linkPreviews
    case westreemEntityCards
    case directMessages
    case voiceRooms
    case videoRooms
    case matrixRTC
    case multipleDevices
    case offlineSending
    case retriesAndIdempotency
    case localCaching
    case syncRecovery
    case endToEndEncryption
    case crossSigning
    case keyBackup
    case keyRecovery
    case deviceVerification
    case controlledFederation
    case applicationServiceBridges
    case nativeShareSheet
    case bridgeShareExperience
    case vibeManagement
    case waveManagement
    case encryptionRecoveryManagement
    case accessibility
    case localization
}

public enum MatrixCapabilityImplementationState: String, Codable, Sendable {
    /// The Phase 1 SDK/session foundation required by the capability exists,
    /// but no user-facing parity claim is implied.
    case foundation
    case planned
    /// Existing infrastructure must report ready before this can be enabled.
    case existingInfrastructureGate
}

public struct MatrixCapabilityPlanEntry: Equatable, Sendable {
    public let capability: MatrixNativeCapability
    public let state: MatrixCapabilityImplementationState
    public let phase: Int

    public init(
        capability: MatrixNativeCapability,
        state: MatrixCapabilityImplementationState,
        phase: Int
    ) {
        self.capability = capability
        self.state = state
        self.phase = phase
    }
}

public enum MatrixNativeCapabilityPlan {
    public static let current: [MatrixCapabilityPlanEntry] =
        MatrixNativeCapability.allCases.map { capability in
            MatrixCapabilityPlanEntry(
                capability: capability,
                state: state(for: capability),
                phase: phase(for: capability)
            )
        }

    public static var isComplete: Bool {
        Set(current.map(\.capability)) == Set(MatrixNativeCapability.allCases)
            && current.count == MatrixNativeCapability.allCases.count
    }

    public static func entry(
        for capability: MatrixNativeCapability
    ) -> MatrixCapabilityPlanEntry {
        current.first { $0.capability == capability }!
    }

    private static func state(
        for capability: MatrixNativeCapability
    ) -> MatrixCapabilityImplementationState {
        switch capability {
        case .secureTokenStorage, .multipleDevices, .localCaching, .syncRecovery, .offlineSending,
             .retriesAndIdempotency, .threads, .endToEndEncryption,
             .crossSigning, .keyBackup, .keyRecovery, .deviceVerification:
            return .foundation
        case .matrixRTC, .voiceRooms, .videoRooms, .applicationServiceBridges,
             .controlledFederation, .pushNotifications:
            return .existingInfrastructureGate
        default:
            return .planned
        }
    }

    private static func phase(for capability: MatrixNativeCapability) -> Int {
        switch capability {
        case .westreemOIDCSSO, .profileSynchronization, .suspensionRevocation,
             .accountDeletionLifecycle, .spaces, .nestedSpaces, .publicRooms, .privateRooms, .roomAliases,
             .membership, .invitations, .rolesAndPowerLevels, .textFormatting,
             .edits, .replies, .threads, .reactionsAndEnergy,
             .echoesAndReferences, .mentions, .readReceipts, .typing, .presence,
             .unreadCounts, .notificationSettings, .pushRules, .pushNotifications,
             .pinning, .roomSearch, .roomHistory,
             .moderation, .reports, .redactions, .polls, .stickers:
            return 2
        case .multipleImageAttachments, .fileAttachments, .voiceMessages,
             .voiceMessagePlayback, .videoMessages, .videoMessagePlayback,
             .mediaViewer, .linkPreviews, .westreemEntityCards,
             .nativeShareSheet, .bridgeShareExperience, .vibeManagement,
             .waveManagement, .accessibility, .localization:
            return 3
        case .directMessages, .voiceRooms, .videoRooms, .matrixRTC,
             .secureTokenStorage, .multipleDevices, .offlineSending, .retriesAndIdempotency,
             .localCaching, .syncRecovery, .endToEndEncryption, .crossSigning,
             .keyBackup, .keyRecovery, .deviceVerification,
             .encryptionRecoveryManagement:
            return 4
        case .controlledFederation, .applicationServiceBridges:
            return 5
        }
    }
}
