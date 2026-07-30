import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeWaveActionsContractTests: XCTestCase {
    private let allowed = (
        roomIsJoined: true,
        senderIsIgnored: false,
        isRemoteEvent: true,
        isOwnEvent: false,
        isUnableToDecrypt: false,
        roomIsEncrypted: false,
        maySendMessage: true,
        maySendReaction: true,
        mayRedactOwn: true,
        mayRedactOther: true,
        mayPin: true
    )

    func testStrongestModelPromptRemainsNormativeSource() {
        XCTAssertEqual(
            MatrixNativeWaveActionPolicy.normativeSource,
            "User strongest-model Matrix-native Vibes prompt (precedence 1)"
        )
    }

    func testEnergyVocabularyUsesVersionedMatrixReactionKeysAndSVGBackedSymbols() {
        XCTAssertEqual(
            MatrixNativeEnergyOption.all.map(\.label),
            ["Hits", "Inspired", "Real", "Deep", "Chill", "Clutch"]
        )
        XCTAssertTrue(
            MatrixNativeEnergyOption.all.allSatisfy {
                $0.id.hasPrefix("com.westreem.energy.v1:")
                    && !$0.systemImage.isEmpty
            }
        )
        XCTAssertEqual(
            Set(MatrixNativeEnergyOption.all.map(\.id)).count,
            MatrixNativeEnergyOption.all.count
        )
    }

    func testEveryActionFailsClosedOutsideJoinedRoom() {
        for action in MatrixNativeWaveAction.allCases {
            XCTAssertFalse(
                permits(action, roomIsJoined: false),
                "\(action) must fail closed outside joined rooms"
            )
        }
    }

    func testEveryActionFailsClosedForIgnoredOrUndecryptableSender() {
        for action in MatrixNativeWaveAction.allCases {
            XCTAssertFalse(permits(action, senderIsIgnored: true))
            XCTAssertFalse(permits(action, isUnableToDecrypt: true))
        }
    }

    func testReplyReportAndPinRequireRemoteEvent() {
        for action in [
            MatrixNativeWaveAction.reply,
            .report,
            .pin,
        ] {
            XCTAssertFalse(permits(action, isRemoteEvent: false))
        }
        XCTAssertTrue(permits(.addEnergy, isRemoteEvent: false))
    }

    func testEditIsAuthorOnlyAndRedactionUsesMatrixPowerLevels() {
        XCTAssertFalse(permits(.edit, isOwnEvent: false))
        XCTAssertTrue(permits(.edit, isOwnEvent: true))
        XCTAssertFalse(
            permits(.redact, isOwnEvent: true, mayRedactOwn: false)
        )
        XCTAssertFalse(
            permits(.redact, isOwnEvent: false, mayRedactOther: false)
        )
    }

    func testEncryptedReportFailsClosedWithoutDecryptedEvidenceAPI() {
        XCTAssertFalse(permits(.report, roomIsEncrypted: true))
        XCTAssertTrue(permits(.reply, roomIsEncrypted: true))
        XCTAssertTrue(permits(.addEnergy, roomIsEncrypted: true))
    }

    func testMessageAndReportNormalizationAreBounded() {
        XCTAssertNil(MatrixNativeWaveActionPolicy.normalizedMessage(" \n "))
        XCTAssertNil(MatrixNativeWaveActionPolicy.normalizedReportReason("  "))
        XCTAssertEqual(
            MatrixNativeWaveActionPolicy.normalizedMessage(
                String(repeating: "a", count: 5_000)
            )?.count,
            4_000
        )
        XCTAssertEqual(
            MatrixNativeWaveActionPolicy.normalizedReportReason(
                String(repeating: "b", count: 1_200)
            )?.count,
            1_000
        )
        XCTAssertEqual(MatrixNativeWaveActionPolicy.replyPreviewLimit, 2)
    }

    func testMentionCompositionUsesSelectedMatrixMembersAndSafeHTML() {
        let ahmed = MatrixNativeMentionTarget(
            userID: "@u_123:vibes.westreem.com",
            displayName: "Ahmed & Co"
        )
        XCTAssertEqual(MatrixNativeMentionComposer.query(in: "Hello @ah"), "ah")
        let text = MatrixNativeMentionComposer.inserting(ahmed, into: "Hello @ah")
        XCTAssertEqual(text, "Hello @Ahmed & Co ")
        XCTAssertEqual(
            MatrixNativeMentionComposer.activeTargets(
                in: text,
                selected: [ahmed, ahmed]
            ),
            [ahmed]
        )
        let html = MatrixNativeMentionComposer.formattedHTML(
            body: "\(text)<safe>",
            mentions: [ahmed]
        )
        XCTAssertEqual(
            html,
            #"Hello <a href="https://matrix.to/#/@u_123:vibes.westreem.com">@Ahmed &amp; Co</a> &lt;safe&gt;"#
        )
    }

    func testMentionQueryDoesNotTriggerInsideWordsOrAfterWhitespace() {
        XCTAssertNil(MatrixNativeMentionComposer.query(in: "email@example.com"))
        XCTAssertNil(MatrixNativeMentionComposer.query(in: "Hello @Ahmed next"))
        XCTAssertEqual(MatrixNativeMentionComposer.query(in: "@"), "")
    }

    private func permits(
        _ action: MatrixNativeWaveAction,
        roomIsJoined: Bool? = nil,
        senderIsIgnored: Bool? = nil,
        isRemoteEvent: Bool? = nil,
        isOwnEvent: Bool? = nil,
        isUnableToDecrypt: Bool? = nil,
        roomIsEncrypted: Bool? = nil,
        maySendMessage: Bool? = nil,
        maySendReaction: Bool? = nil,
        mayRedactOwn: Bool? = nil,
        mayRedactOther: Bool? = nil,
        mayPin: Bool? = nil
    ) -> Bool {
        MatrixNativeWaveActionPolicy.permits(
            action,
            roomIsJoined: roomIsJoined ?? allowed.roomIsJoined,
            senderIsIgnored: senderIsIgnored ?? allowed.senderIsIgnored,
            isRemoteEvent: isRemoteEvent ?? allowed.isRemoteEvent,
            isOwnEvent: isOwnEvent ?? allowed.isOwnEvent,
            isUnableToDecrypt: isUnableToDecrypt ?? allowed.isUnableToDecrypt,
            roomIsEncrypted: roomIsEncrypted ?? allowed.roomIsEncrypted,
            maySendMessage: maySendMessage ?? allowed.maySendMessage,
            maySendReaction: maySendReaction ?? allowed.maySendReaction,
            mayRedactOwn: mayRedactOwn ?? allowed.mayRedactOwn,
            mayRedactOther: mayRedactOther ?? allowed.mayRedactOther,
            mayPin: mayPin ?? allowed.mayPin
        )
    }
}
