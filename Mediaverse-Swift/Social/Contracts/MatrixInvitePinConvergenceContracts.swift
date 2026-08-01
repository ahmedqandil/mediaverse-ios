import Foundation

public struct MatrixInviteDeclineBlockPlan: Equatable, Sendable {
    public let inviterUserID: String
    public let mustAddIgnore: Bool

    public init(inviterUserID: String, mustAddIgnore: Bool) {
        self.inviterUserID = inviterUserID
        self.mustAddIgnore = mustAddIgnore
    }
}

public enum MatrixInviteDeclineBlockContract {
    public static func plan(
        membershipIsInvited: Bool,
        inviterUserID: String?,
        currentUserID: String,
        ignoredUserIDs: Set<String>
    ) -> MatrixInviteDeclineBlockPlan? {
        guard membershipIsInvited,
              let inviter = inviterUserID?.trimmingCharacters(in: .whitespacesAndNewlines),
              inviter.first == "@",
              inviter.contains(":"),
              inviter != currentUserID
        else { return nil }
        return MatrixInviteDeclineBlockPlan(
            inviterUserID: inviter,
            mustAddIgnore: !ignoredUserIDs.contains(inviter)
        )
    }

    public static func mustRollbackNewIgnore(
        plan: MatrixInviteDeclineBlockPlan,
        leaveSucceeded: Bool
    ) -> Bool {
        plan.mustAddIgnore && !leaveSucceeded
    }
}

public enum MatrixInvitationKind: String, Equatable, Sendable {
    case vibe
    case wave
    case personalWave
}

public struct MatrixInvitationSafety: Equatable, Sendable {
    public let canAccept: Bool
    public let canDecline: Bool
    public let canBlock: Bool
    public let reason: String?
}

/// Presentation policy only. Matrix membership is reread by repository-owned
/// mutations immediately before join/leave/ignore, matching Element's invite
/// screen separation between rendering and authority.
public enum MatrixInvitationSafetyContract {
    public static func evaluate(
        membershipIsInvited: Bool,
        kind: MatrixInvitationKind,
        isEncrypted: Bool,
        inviterIsBlocked: Bool,
        inviterUserID: String?
    ) -> MatrixInvitationSafety {
        guard membershipIsInvited else {
            return .init(
                canAccept: false,
                canDecline: false,
                canBlock: false,
                reason: "This invitation is no longer available."
            )
        }
        let inviterValid = inviterUserID?.first == "@"
            && inviterUserID?.contains(":") == true
        if inviterIsBlocked {
            return .init(
                canAccept: false,
                canDecline: true,
                canBlock: false,
                reason: "Unblock this person before accepting the invitation."
            )
        }
        if kind == .personalWave && !inviterValid {
            return .init(
                canAccept: false,
                canDecline: true,
                canBlock: false,
                reason: "The Personal Wave inviter could not be verified."
            )
        }
        return .init(
            canAccept: true,
            canDecline: true,
            canBlock: inviterValid,
            reason: inviterValid ? nil : "Inviter details are unavailable. Blocking is disabled."
        )
    }
}

public enum MatrixPinnedEventFallbackContract {
    public static let sender = "Unavailable"
    public static let body = "Pinned Ripple unavailable"
    public static let detail = "This Ripple is missing or you no longer have permission to view it."

    public static func mayUnpin(canManagePins: Bool) -> Bool { canManagePins }
}

public enum MatrixPinnedEventMutationDecision: Equatable, Sendable {
    case mutate
    case noOp
    case deny
}

public enum MatrixPinnedEventMutationContract {
    public static let maximumPinnedEvents = 100

    public static func decide(
        eventID: String,
        pinned: Bool,
        currentPinnedEventIDs: Set<String>,
        canManagePins: Bool,
        eventIsAvailable: Bool,
        senderMatches: Bool,
        senderIsIgnored: Bool
    ) -> MatrixPinnedEventMutationDecision {
        guard canManagePins,
              eventID.first == "$",
              eventID.count <= 512,
              !eventID.contains(where: { $0.isWhitespace }) else {
            return .deny
        }
        let alreadyPinned = currentPinnedEventIDs.contains(eventID)
        guard alreadyPinned != pinned else { return .noOp }
        // Missing/redacted/blocked events may still be unpinned. Pinning is
        // stricter because it creates new room state from a live event.
        if !pinned { return .mutate }
        guard currentPinnedEventIDs.count < maximumPinnedEvents,
              eventIsAvailable,
              senderMatches,
              !senderIsIgnored else {
            return .deny
        }
        return .mutate
    }
}
