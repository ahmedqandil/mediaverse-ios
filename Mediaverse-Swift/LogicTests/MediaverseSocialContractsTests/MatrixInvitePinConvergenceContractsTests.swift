import XCTest
@testable import MediaverseSocialContracts

final class MatrixInvitePinConvergenceContractsTests: XCTestCase {
    func testDeclineAndBlockPlansOnlyAValidatedLiveInviter() {
        let plan = MatrixInviteDeclineBlockContract.plan(
            membershipIsInvited: true,
            inviterUserID: "@inviter:example.org",
            currentUserID: "@me:example.org",
            ignoredUserIDs: []
        )
        XCTAssertEqual(plan?.inviterUserID, "@inviter:example.org")
        XCTAssertEqual(plan?.mustAddIgnore, true)
        XCTAssertNil(MatrixInviteDeclineBlockContract.plan(
            membershipIsInvited: false,
            inviterUserID: "@inviter:example.org",
            currentUserID: "@me:example.org",
            ignoredUserIDs: []
        ))
        XCTAssertNil(MatrixInviteDeclineBlockContract.plan(
            membershipIsInvited: true,
            inviterUserID: "@me:example.org",
            currentUserID: "@me:example.org",
            ignoredUserIDs: []
        ))
    }

    func testRollbackAppliesOnlyToIgnoreAddedByThisOperation() {
        XCTAssertTrue(MatrixInviteDeclineBlockContract.mustRollbackNewIgnore(
            plan: .init(inviterUserID: "@i:example.org", mustAddIgnore: true),
            leaveSucceeded: false
        ))
        XCTAssertFalse(MatrixInviteDeclineBlockContract.mustRollbackNewIgnore(
            plan: .init(inviterUserID: "@i:example.org", mustAddIgnore: false),
            leaveSucceeded: false
        ))
        XCTAssertFalse(MatrixInviteDeclineBlockContract.mustRollbackNewIgnore(
            plan: .init(inviterUserID: "@i:example.org", mustAddIgnore: true),
            leaveSucceeded: true
        ))
    }

    func testMissingPinCopyIsExplicitAndUnpinRemainsCapabilityGated() {
        XCTAssertEqual(MatrixPinnedEventFallbackContract.body, "Pinned Ripple unavailable")
        XCTAssertTrue(MatrixPinnedEventFallbackContract.mayUnpin(canManagePins: true))
        XCTAssertFalse(MatrixPinnedEventFallbackContract.mayUnpin(canManagePins: false))
    }

    func testPinMutationIsIdempotentBoundedAndRequiresAnAvailableMatchingEvent() {
        XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
            eventID: "$event",
            pinned: true,
            currentPinnedEventIDs: [],
            canManagePins: true,
            eventIsAvailable: true,
            senderMatches: true,
            senderIsIgnored: false
        ), .mutate)
        XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
            eventID: "$event",
            pinned: true,
            currentPinnedEventIDs: ["$event"],
            canManagePins: true,
            eventIsAvailable: true,
            senderMatches: true,
            senderIsIgnored: false
        ), .noOp)
        XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
            eventID: "$new",
            pinned: true,
            currentPinnedEventIDs: Set((0..<100).map { "$\($0)" }),
            canManagePins: true,
            eventIsAvailable: true,
            senderMatches: true,
            senderIsIgnored: false
        ), .deny)
        for (available, matches, ignored) in [
            (false, true, false), (true, false, false), (true, true, true),
        ] {
            XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
                eventID: "$event",
                pinned: true,
                currentPinnedEventIDs: [],
                canManagePins: true,
                eventIsAvailable: available,
                senderMatches: matches,
                senderIsIgnored: ignored
            ), .deny)
        }
    }

    func testMissingOrRedactedPinCanBeUnpinnedOnlyWithCurrentPermission() {
        XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
            eventID: "$missing",
            pinned: false,
            currentPinnedEventIDs: ["$missing"],
            canManagePins: true,
            eventIsAvailable: false,
            senderMatches: false,
            senderIsIgnored: true
        ), .mutate)
        XCTAssertEqual(MatrixPinnedEventMutationContract.decide(
            eventID: "$missing",
            pinned: false,
            currentPinnedEventIDs: ["$missing"],
            canManagePins: false,
            eventIsAvailable: false,
            senderMatches: false,
            senderIsIgnored: true
        ), .deny)
    }

    func testAllInvitationKindsAreAcceptedOnlyWhileLiveAndPersonalWavesRequireEncryption() {
        for kind in [MatrixInvitationKind.vibe, .wave, .personalWave] {
            let safety = MatrixInvitationSafetyContract.evaluate(
                membershipIsInvited: true,
                kind: kind,
                isEncrypted: true,
                inviterIsBlocked: false,
                inviterUserID: "@alice:example.org"
            )
            XCTAssertTrue(safety.canAccept)
            XCTAssertTrue(safety.canDecline)
        }
        XCTAssertFalse(MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: .personalWave,
            isEncrypted: false,
            inviterIsBlocked: false,
            inviterUserID: "@alice:example.org"
        ).canAccept)
        XCTAssertFalse(MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: .personalWave,
            isEncrypted: true,
            inviterIsBlocked: false,
            inviterUserID: nil
        ).canAccept)
        XCTAssertFalse(MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: false,
            kind: .wave,
            isEncrypted: true,
            inviterIsBlocked: false,
            inviterUserID: "@alice:example.org"
        ).canDecline)
    }

    func testBlockedAndMissingInviterPoliciesFailClosedWithoutRemovingDecline() {
        let blocked = MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: .vibe,
            isEncrypted: false,
            inviterIsBlocked: true,
            inviterUserID: "@blocked:example.org"
        )
        XCTAssertFalse(blocked.canAccept)
        XCTAssertTrue(blocked.canDecline)
        XCTAssertFalse(blocked.canBlock)

        let missing = MatrixInvitationSafetyContract.evaluate(
            membershipIsInvited: true,
            kind: .wave,
            isEncrypted: false,
            inviterIsBlocked: false,
            inviterUserID: nil
        )
        XCTAssertTrue(missing.canAccept)
        XCTAssertTrue(missing.canDecline)
        XCTAssertFalse(missing.canBlock)
    }
}
