import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeVibesUIContractTests: XCTestCase {
    func testSlidingSyncScaleWindowsCoverTenThousandRoomsInBoundedBatches() {
        for total in [10, 100, 1_000, 10_000] {
            var range = MatrixNativeSlidingSyncScaleContract.initialRange(
                totalRooms: total
            )
            var requests = range == nil ? 0 : 1
            while let current = range,
                  let next = MatrixNativeSlidingSyncScaleContract.nextRange(
                    totalRooms: total,
                    current: current
                  ) {
                XCTAssertLessThanOrEqual(
                    next.upperBound - current.upperBound,
                    MatrixNativeSlidingSyncScaleContract.batchRooms
                )
                range = next
                requests += 1
            }
            XCTAssertEqual(range?.upperBound, total - 1)
            XCTAssertLessThanOrEqual(requests, 201)
        }
    }

    func testSlidingSyncActiveSubscriptionRemainsReplaceOnlyAcrossTenThousandSwitches() {
        var subscription = Set<String>()
        for index in 0..<10_000 {
            subscription = MatrixNativeSlidingSyncScaleContract
                .activeSubscription(roomID: "!wave-\(index):example.org")
            XCTAssertEqual(subscription.count, 1)
        }
        XCTAssertEqual(subscription, ["!wave-9999:example.org"])
        XCTAssertTrue(MatrixNativeSlidingSyncScaleContract
            .activeSubscription(roomID: "not-a-room").isEmpty)
    }
    func testMatrixAvatarPolicyAcceptsBoundedRasterAndRejectsUnsafeContent() throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47])
        png.append(Data(repeating: 0, count: 32))
        XCTAssertTrue(MatrixNativeAvatarContract.accepts(png))
        XCTAssertFalse(MatrixNativeAvatarContract.accepts(Data("<svg/>".utf8)))
        XCTAssertFalse(
            MatrixNativeAvatarContract.accepts(
                Data(repeating: 0xFF, count: MatrixNativeAvatarContract.maximumBytes + 1)
            )
        )
    }
    func testNativeVibesUISliceRemainsMatrixAuthoritative() {
        XCTAssertEqual(MatrixNativeVibesUIContract.authority, .matrix)
        XCTAssertEqual(
            MatrixNativeVibesUIContract.normativeSource,
            "User strongest-model Matrix-native Vibes prompt (precedence 1)"
        )
    }

    func testMissingSyncedProfileNeverExposesRawMatrixIdentity() {
        let matrixUserID = "@u_123:vibes.westreem.com"
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.displayName(
                nil,
                matrixUserID: matrixUserID
            ),
            "WeStreem member"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.displayName(
                matrixUserID,
                matrixUserID: matrixUserID
            ),
            "WeStreem member"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.displayName(
                "u_123",
                matrixUserID: matrixUserID
            ),
            "WeStreem member"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.displayName(
                "Ahmed Qandil",
                matrixUserID: matrixUserID
            ),
            "Ahmed Qandil"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.roomName(
                "!private:vibes.westreem.com",
                fallback: "Wave"
            ),
            "Wave"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.roomName(
                "#general:vibes.westreem.com",
                fallback: "Wave"
            ),
            "Wave"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.directRoomName(
                peerDisplayName: "Ahmed Qandil",
                roomDisplayName: "Empty Room (was u_636d727)",
                peerMatrixUserID: "@u_636d727:vibes.westreem.com"
            ),
            "Ahmed Qandil"
        )
        XCTAssertEqual(
            MatrixNativeMemberPresentationContract.directRoomName(
                peerDisplayName: "u_636d727",
                roomDisplayName: "Empty Room (was u_636d727)",
                peerMatrixUserID: "@u_636d727:vibes.westreem.com"
            ),
            "Personal Wave"
        )
    }

    func testNativeVibesUISliceDeclaresEveryBoundedAcceptanceSurface() {
        XCTAssertEqual(
            MatrixNativeVibesUIContract.required,
            Set(MatrixNativeVibesUISurface.allCases)
        )
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.legacyRouteFailClosed))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.sdkLocalSendState))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.offlineState))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.publicSpaceDirectory))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.publicSpaceSearch))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.publicSpacePagination))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.publicSpaceJoin))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.createSpace))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.createRoomInSpace))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.matrixUserInvitations))
        XCTAssertTrue(MatrixNativeVibesUIContract.required.contains(.powerLevelPermissionGates))
    }

    func testSpaceDirectoryFailureOnlyIgnoresExplicitlyInaccessibleTombstones() {
        for errorCode in ["M_NOT_FOUND", "M_FORBIDDEN"] {
            XCTAssertEqual(
                MatrixNativeSpaceDirectoryFailureContract.disposition(
                    matrixErrorCode: errorCode
                ),
                .ignoreStalePurgedSpace
            )
        }
        XCTAssertEqual(
            MatrixNativeSpaceDirectoryFailureContract.disposition(
                matrixErrorCode: "M_UNKNOWN",
                matrixKindIsNotFound: true
            ),
            .ignoreStalePurgedSpace
        )
        for errorCode in [nil, "M_UNKNOWN", "M_LIMIT_EXCEEDED"] {
            XCTAssertEqual(
                MatrixNativeSpaceDirectoryFailureContract.disposition(
                    matrixErrorCode: errorCode,
                    matrixKindIsNotFound: false
                ),
                .reportFailure
            )
        }
    }

    func testCreationDraftIsTrimmedAndInvitationsAreDeduplicated() throws {
        let validated = try MatrixNativeCreationContract.validate(
            MatrixNativeRoomCreationDraft(
                name: "  Film Makers  ",
                topic: "  Share production knowledge.  ",
                visibility: .publicVibe,
                inviteUserIDs: [
                    " @alice:example.org ",
                    "@bob:example.org",
                    "@alice:example.org",
                ],
                canonicalAlias: "#film-makers:example.org"
            )
        )

        XCTAssertEqual(validated.name, "Film Makers")
        XCTAssertEqual(validated.topic, "Share production knowledge.")
        XCTAssertEqual(validated.visibility, .publicVibe)
        XCTAssertEqual(
            validated.inviteUserIDs,
            ["@alice:example.org", "@bob:example.org"]
        )
    }

    func testCreationValidationFailsClosedForMalformedIdentityAndBounds() {
        XCTAssertThrowsError(
            try MatrixNativeCreationContract.validate(
                MatrixNativeRoomCreationDraft(
                    name: "Vibe",
                    topic: "",
                    visibility: .privateVibe,
                    inviteUserIDs: ["alice@example.org"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? MatrixNativeCreationValidationError,
                .invalidMatrixUserID("alice@example.org")
            )
        }

        XCTAssertThrowsError(
            try MatrixNativeCreationContract.validate(
                MatrixNativeRoomCreationDraft(
                    name: String(repeating: "x", count: 256),
                    topic: "",
                    visibility: .publicVibe,
                    inviteUserIDs: [],
                    canonicalAlias: "#too-long:example.org"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? MatrixNativeCreationValidationError,
                .invalidName
            )
        }
    }

    func testCreationAccessAndPublicAliasRemainExplicit() throws {
        let knock = try MatrixNativeCreationContract.validate(
            MatrixNativeRoomCreationDraft(
                name: "Requests",
                topic: "",
                visibility: .knock,
                inviteUserIDs: []
            )
        )
        XCTAssertEqual(knock.visibility, .knock)
        XCTAssertNil(knock.canonicalAlias)

        XCTAssertThrowsError(try MatrixNativeCreationContract.validate(
            MatrixNativeRoomCreationDraft(
                name: "Public",
                topic: "",
                visibility: .publicVibe,
                inviteUserIDs: [],
                canonicalAlias: "not-an-alias"
            )
        )) { error in
            XCTAssertEqual(error as? MatrixNativeCreationValidationError, .invalidCanonicalAlias)
        }
    }

    func testCreationAvatarAcceptsOnlyBoundedImagePayloads() throws {
        let avatar = MatrixNativeRoomCreationAvatar(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            filename: "vibe-avatar.png",
            mimeType: "image/png",
            width: 256,
            height: 256
        )
        let validated = try MatrixNativeCreationContract.validate(
            MatrixNativeRoomCreationDraft(
                name: "Film Makers",
                topic: "",
                visibility: .privateVibe,
                inviteUserIDs: [],
                avatar: avatar
            )
        )
        XCTAssertEqual(validated.avatar, avatar)

        for invalid in [
            MatrixNativeRoomCreationAvatar(
                data: Data(),
                filename: "empty.png",
                mimeType: "image/png"
            ),
            MatrixNativeRoomCreationAvatar(
                data: Data([0x01]),
                filename: "script.svg",
                mimeType: "text/html"
            ),
            MatrixNativeRoomCreationAvatar(
                data: Data(
                    repeating: 0x01,
                    count: MatrixNativeCreationContract.maximumAvatarBytes + 1
                ),
                filename: "large.png",
                mimeType: "image/png"
            ),
        ] {
            XCTAssertThrowsError(
                try MatrixNativeCreationContract.validate(
                    MatrixNativeRoomCreationDraft(
                        name: "Film Makers",
                        topic: "",
                        visibility: .privateVibe,
                        inviteUserIDs: [],
                        avatar: invalid
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? MatrixNativeCreationValidationError,
                    .invalidAvatar
                )
            }
        }
    }

    func testInviteParserAcceptsCommaAndLineSeparatedMatrixIDs() {
        XCTAssertEqual(
            MatrixNativeCreationContract.parseInviteUserIDs(
                "@alice:example.org,\n@bob:example.org"
            ),
            ["@alice:example.org", "@bob:example.org"]
        )
    }

    func testVibeInviteSearchRequiresBoundedExplicitQueryAndSelection() {
        XCTAssertNil(WestreemVibeInviteSearchContract.normalizedQuery(" a "))
        XCTAssertNil(
            WestreemVibeInviteSearchContract.normalizedQuery(
                String(repeating: "a", count: 65)
            )
        )
        XCTAssertEqual(
            WestreemVibeInviteSearchContract.normalizedQuery("  @ahmed  "),
            "@ahmed"
        )
        XCTAssertEqual(
            WestreemVibeInviteSearchContract.uniqueSelection(
                [" bound-1 ", "bound-2", "bound-1", ""]
            ),
            ["bound-1", "bound-2"]
        )
        XCTAssertTrue(
            WestreemVibeInviteSearchContract.canSubmit(["bound-1"])
        )
        XCTAssertFalse(WestreemVibeInviteSearchContract.canSubmit([]))
    }

    func testContactDiscoveryNormalizesLocallyAndBoundsOnlyValidHashes() {
        XCTAssertEqual(
            WestreemVibeContactDiscoveryContract.normalizedEmail(
                "  Person@Example.COM "
            ),
            "person@example.com"
        )
        XCTAssertNil(
            WestreemVibeContactDiscoveryContract.normalizedEmail("not-an-email")
        )
        XCTAssertEqual(
            WestreemVibeContactDiscoveryContract.normalizedPhone(
                " +1 (415) 555-0100 "
            ),
            "+14155550100"
        )
        XCTAssertNil(
            WestreemVibeContactDiscoveryContract.normalizedPhone("123")
        )

        let valid = String(repeating: "a", count: 64)
        let values = [valid, valid.uppercased(), "not-a-hash"]
        XCTAssertEqual(
            WestreemVibeContactDiscoveryContract.boundedHashes(values),
            [valid]
        )
    }

    func testSpacePermissionsRequireJoinedSpaceAndSDKPowerLevel() {
        XCTAssertFalse(MatrixNativeSpacePermissionSnapshot.unavailable.mayCreateWave)
        XCTAssertFalse(MatrixNativeSpacePermissionSnapshot.unavailable.mayInviteMembers)
        XCTAssertFalse(MatrixNativeSpacePermissionSnapshot.unavailable.mayOpenVibeManagement)

        let manager = MatrixNativeSpacePermissionSnapshot(
            isJoined: true,
            isSpace: true,
            maySendSpaceChild: true,
            mayInvite: true
        )
        XCTAssertTrue(manager.mayCreateWave)
        XCTAssertTrue(manager.mayInviteMembers)
        XCTAssertTrue(manager.mayOpenVibeManagement)

        let ordinaryMember = MatrixNativeSpacePermissionSnapshot(
            isJoined: true,
            isSpace: true,
            maySendSpaceChild: false,
            mayInvite: false
        )
        XCTAssertFalse(ordinaryMember.mayCreateWave)
        XCTAssertFalse(ordinaryMember.mayInviteMembers)
        XCTAssertTrue(ordinaryMember.mayOpenVibeManagement)
    }

    func testSafeLinkPreviewExtractsPublicLinksAndRejectsLocalTargets() throws {
        XCTAssertEqual(
            MatrixNativeLinkPreviewContract.firstPublicHTTPURL(
                in: "Worth reading: https://example.com/story?q=1."
            ),
            "https://example.com/story?q=1"
        )
        XCTAssertNil(
            MatrixNativeLinkPreviewContract.firstPublicHTTPURL(
                in: "http://127.0.0.1/admin"
            )
        )
        XCTAssertNil(
            MatrixNativeLinkPreviewContract.safePublicHTTPURL(
                "https://user:secret@example.com/"
            )
        )
        XCTAssertNil(
            MatrixNativeLinkPreviewContract.safePublicHTTPURL(
                "https://example.com:8443/admin"
            )
        )
        XCTAssertNil(
            MatrixNativeLinkPreviewContract.safePublicHTTPURL(
                "file:///etc/passwd"
            )
        )
        XCTAssertNoThrow(
            try MatrixNativeLinkPreviewMetadata(
                title: "Story",
                description: "Safe server-derived preview.",
                imageURL: "https://cdn.example.com/image.jpg",
                faviconURL: nil,
                domain: "example.com",
                finalURL: "https://example.com/story"
            )
        )
    }

    func testLinkPreviewCacheIsolatesAccountsExpiresAndEvicts() throws {
        let metadata = try MatrixNativeLinkPreviewMetadata(
            title: "Story",
            description: nil,
            imageURL: nil,
            faviconURL: nil,
            domain: "example.com",
            finalURL: "https://example.com/story"
        )
        let now = Date(timeIntervalSince1970: 1_000)
        var cache = MatrixNativeLinkPreviewCache()
        cache.insert(metadata, accountScope: "account-a", url: metadata.finalURL, now: now)
        XCTAssertNil(cache.value(accountScope: "account-b", url: metadata.finalURL, now: now))
        XCTAssertEqual(
            cache.value(accountScope: "account-a", url: metadata.finalURL, now: now),
            metadata
        )
        XCTAssertNil(
            cache.value(
                accountScope: "account-a",
                url: metadata.finalURL,
                now: now.addingTimeInterval(MatrixNativeLinkPreviewCache.timeToLive + 1)
            )
        )

        for index in 0...MatrixNativeLinkPreviewCache.maximumEntriesPerAccount {
            cache.insert(
                metadata,
                accountScope: "bounded",
                url: "https://example.com/\(index)",
                now: now.addingTimeInterval(Double(index))
            )
        }
        XCTAssertNil(cache.value(accountScope: "bounded", url: "https://example.com/0", now: now))
        cache.clear(accountScope: "bounded")
        XCTAssertNil(cache.value(accountScope: "bounded", url: "https://example.com/100", now: now))
    }

    func testMatrixEchoPreservesDurableSourceProvenance() throws {
        let value = try MatrixNativeMatrixEchoContract.reference(
            sourceRoomID: "!wave:vibes.westreem.com",
            sourceEventID: "$event",
            sourceSenderMatrixUserID: "@u_author:vibes.westreem.com",
            sourceSenderName: "Ahmed",
            sourceBody: "An original Matrix message",
            actorWestreemUserID: "westreem-user-1",
            idempotencyKey: "ios-echo-1"
        )
        XCTAssertEqual(value.entityType, "matrix_event")
        XCTAssertEqual(value.provenance.sourceRoomID, "!wave:vibes.westreem.com")
        XCTAssertEqual(value.provenance.sourceEventID, "$event")
        XCTAssertEqual(
            value.provenance.sourceSenderMatrixUserID,
            "@u_author:vibes.westreem.com"
        )
        XCTAssertEqual(
            value.provenance.hopTrace,
            [
                MatrixNativeWestreemProvenanceHopV1(
                    roomID: "!wave:vibes.westreem.com",
                    eventID: "$event",
                    senderMatrixUserID: "@u_author:vibes.westreem.com"
                )
            ]
        )
        XCTAssertEqual(value.provenance.sourceProduct, "vibes")
        XCTAssertEqual(value.summary, "An original Matrix message")
        XCTAssertThrowsError(
            try MatrixNativeMatrixEchoContract.reference(
                sourceRoomID: "!wave:vibes.westreem.com",
                sourceEventID: "not-an-event",
                sourceSenderMatrixUserID: "@u_author:vibes.westreem.com",
                sourceSenderName: "Ahmed",
                sourceBody: "Message",
                actorWestreemUserID: "westreem-user-1",
                idempotencyKey: "ios-echo-2"
            )
        )
    }

    func testMatrixEchoDestinationsAreBoundedAndRetriesAreStable() {
        let destinations = (0..<24).map {
            "!wave-\($0):vibes.westreem.com"
        } + [
            "!wave-0:vibes.westreem.com",
            "not-a-room",
        ]
        let bounded = MatrixNativeMatrixEchoContract
            .boundedDestinationRoomIDs(destinations)
        XCTAssertEqual(bounded.count, 20)
        XCTAssertEqual(bounded.first, "!wave-0:vibes.westreem.com")
        XCTAssertEqual(bounded.last, "!wave-19:vibes.westreem.com")

        let first = MatrixNativeMatrixEchoContract.stableTransactionID(
            requestID: "request-1",
            destinationRoomID: "!wave-1:vibes.westreem.com"
        )
        XCTAssertEqual(
            first,
            MatrixNativeMatrixEchoContract.stableTransactionID(
                requestID: "request-1",
                destinationRoomID: "!wave-1:vibes.westreem.com"
            )
        )
        XCTAssertNotEqual(
            first,
            MatrixNativeMatrixEchoContract.stableTransactionID(
                requestID: "request-1",
                destinationRoomID: "!wave-2:vibes.westreem.com"
            )
        )
        XCTAssertNotNil(
            first.range(
                of: #"^[A-Za-z0-9._:~-]+$"#,
                options: .regularExpression
            )
        )
    }

    func testMatrixEchoCarriesHopTraceAndRejectsCyclesOrForgedHistory() throws {
        let first = try MatrixNativeMatrixEchoContract.reference(
            sourceRoomID: "!first:vibes.westreem.com",
            sourceEventID: "$first",
            sourceSenderMatrixUserID: "@u_first:vibes.westreem.com",
            sourceSenderName: "First",
            sourceBody: "Original",
            actorWestreemUserID: "westreem-user-1",
            idempotencyKey: "ios-echo-first"
        )
        let second = try MatrixNativeMatrixEchoContract.reference(
            sourceRoomID: "!second:vibes.westreem.com",
            sourceEventID: "$second",
            sourceSenderMatrixUserID: "@u_second:vibes.westreem.com",
            sourceSenderName: "Second",
            sourceBody: "Forwarded",
            actorWestreemUserID: "westreem-user-2",
            existingReference: first,
            idempotencyKey: "ios-echo-second"
        )
        XCTAssertEqual(second.provenance.hopTrace?.count, 2)
        XCTAssertFalse(
            MatrixNativeMatrixEchoContract.canEcho(
                existingReference: second,
                to: "!first:vibes.westreem.com"
            )
        )
        XCTAssertFalse(
            MatrixNativeMatrixEchoContract.canEcho(
                existingReference: second,
                to: "!second:vibes.westreem.com"
            )
        )

        let forged = MatrixNativeWestreemReferenceV1(
            entityType: "matrix_event",
            entityID: "$forged",
            canonicalURL: "https://www.westreem.com/vibes",
            title: "Forged",
            summary: "Forged",
            provenance: MatrixNativeWestreemProvenanceV1(
                sourceProduct: "westreem",
                actorWestreemUserID: "attacker",
                sourceRoomID: "!forged:vibes.westreem.com",
                sourceEventID: "$forged",
                sourceSenderMatrixUserID: "@attacker:vibes.westreem.com",
                hopTrace: [
                    MatrixNativeWestreemProvenanceHopV1(
                        roomID: "!forged:vibes.westreem.com",
                        eventID: "$forged",
                        senderMatrixUserID: "@attacker:vibes.westreem.com"
                    )
                ]
            ),
            idempotencyKey: "forged"
        )
        XCTAssertThrowsError(
            try MatrixNativeMatrixEchoContract.reference(
                sourceRoomID: "!third:vibes.westreem.com",
                sourceEventID: "$third",
                sourceSenderMatrixUserID: "@u_third:vibes.westreem.com",
                sourceSenderName: "Third",
                sourceBody: "Forwarded forged content",
                actorWestreemUserID: "westreem-user-3",
                existingReference: forged,
                idempotencyKey: "ios-echo-third"
            )
        )
    }

    func testMatrixEchoRejectsMissingFirstHopSenderProvenance() {
        let invalid = MatrixNativeWestreemReferenceV1(
            entityType: "matrix_event",
            entityID: "!wave:vibes.westreem.com|$event",
            canonicalURL: "https://www.westreem.com/vibes",
            title: "Shared Ripple",
            summary: "Message",
            provenance: MatrixNativeWestreemProvenanceV1(
                sourceProduct: "vibes",
                actorWestreemUserID: "westreem-user-1",
                sourceRoomID: "!wave:vibes.westreem.com",
                sourceEventID: "$event"
            ),
            idempotencyKey: "ios-echo-invalid"
        )
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceContract.validate(
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                value: invalid
            )
        )
    }

    func testMediaSliceClaimsItsBoundedNativeSurfaces() {
        let required = MatrixNativeVibesUIContract.required
        XCTAssertTrue(required.contains(.nativeAttachmentComposer))
        XCTAssertTrue(required.contains(.polls))
        XCTAssertTrue(required.contains(.stickers))
        XCTAssertTrue(required.contains(.multiplePhotos))
        XCTAssertTrue(required.contains(.files))
        XCTAssertTrue(required.contains(.voiceCapture))
        XCTAssertTrue(required.contains(.voicePlayback))
        XCTAssertTrue(required.contains(.videoCapture))
        XCTAssertTrue(required.contains(.videoPlayback))
        XCTAssertTrue(required.contains(.mediaViewer))
        XCTAssertTrue(required.contains(.attachmentValidationAndLimits))
        XCTAssertTrue(required.contains(.legacyEncryptedMediaIsolation))
    }

    func testSecurityAndRealtimeCapabilitiesReportImplementationAndRuntimeTruth() {
        let implemented = MatrixNativeVibesUIContract.implementedAndContractQAVerified
        XCTAssertTrue(implemented.contains(.directMessages))
        XCTAssertTrue(
            MatrixNativeVibesUIContract.runtimeVerificationPending
                .contains(.directMessages)
        )
        for capability in [
            MatrixNativeCapability.endToEndEncryption,
            .crossSigning,
            .keyBackup,
            .keyRecovery,
            .deviceVerification,
        ] {
            XCTAssertFalse(implemented.contains(capability))
            XCTAssertFalse(
                MatrixNativeVibesUIContract.runtimeVerificationPending
                    .contains(capability)
            )
        }
        XCTAssertFalse(implemented.contains(.matrixRTC))
        XCTAssertTrue(
            MatrixNativeVibesUIContract.runtimeVerificationPending
                .contains(.matrixRTC)
        )
        XCTAssertTrue(MatrixNativeVibesUIContract.supportsWaveMatrixRTC)
        XCTAssertFalse(MatrixNativeVibesUIContract.supportsEncryptedWaveMatrixRTC)
        XCTAssertFalse(MatrixNativeVibesUIContract.supportsDirectMatrixRTC)
    }

    func testVideoAndVoiceDurationMustBeKnownFinitePositiveAndBounded() {
        for kind in [MatrixNativeMediaDurationKind.video, .voice] {
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(nil, for: kind))
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(0, for: kind))
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(-1, for: kind))
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(.infinity, for: kind))
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(.nan, for: kind))
            XCTAssertTrue(MatrixNativeMediaSafetyContract.acceptsDuration(1, for: kind))
            XCTAssertTrue(MatrixNativeMediaSafetyContract.acceptsDuration(600, for: kind))
            XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(600.001, for: kind))
        }
    }

    func testOrdinaryAudioMayOmitDurationButRejectsInvalidDeclaredDuration() {
        XCTAssertTrue(MatrixNativeMediaSafetyContract.acceptsDuration(nil, for: .audio))
        XCTAssertTrue(MatrixNativeMediaSafetyContract.acceptsDuration(42, for: .audio))
        XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(0, for: .audio))
        XCTAssertFalse(MatrixNativeMediaSafetyContract.acceptsDuration(.infinity, for: .audio))
    }

    func testUndisclosedPollHidesEveryResultUntilEnded() {
        XCTAssertFalse(
            MatrixNativePollVisibilityContract.showsResults(
                isDisclosed: false,
                hasEnded: false
            )
        )
        XCTAssertFalse(
            MatrixNativePollVisibilityContract.showsResults(
                isDisclosed: true,
                hasEnded: false
            )
        )
        XCTAssertTrue(
            MatrixNativePollVisibilityContract.showsResults(
                isDisclosed: true,
                hasEnded: false,
                hasVoted: true
            )
        )
        XCTAssertTrue(
            MatrixNativePollVisibilityContract.showsResults(
                isDisclosed: false,
                hasEnded: true
            )
        )
    }

    func testApprovedStickerBytesFailClosedOnTypeConfusion() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let gif = Data("GIF89a-preview".utf8)
        let webp = Data("RIFF1234WEBPpreview".utf8)

        XCTAssertTrue(
            MatrixNativeApprovedStickerContract.accepts(png, mimeType: "image/png")
        )
        XCTAssertTrue(
            MatrixNativeApprovedStickerContract.accepts(gif, mimeType: "image/gif")
        )
        XCTAssertTrue(
            MatrixNativeApprovedStickerContract.accepts(webp, mimeType: "image/webp")
        )
        XCTAssertFalse(
            MatrixNativeApprovedStickerContract.accepts(png, mimeType: "image/webp")
        )
        XCTAssertFalse(
            MatrixNativeApprovedStickerContract.accepts(
                Data("<script>alert(1)</script>".utf8),
                mimeType: "image/png"
            )
        )
        XCTAssertFalse(
            MatrixNativeApprovedStickerContract.accepts(Data(), mimeType: "image/png")
        )
    }

    func testManualRetryNeverRecreatesRichPayloads() {
        XCTAssertTrue(
            MatrixNativeRetryContract.permitsManualRetry(
                for: .text,
                hasLiveSendHandle: true
            )
        )
        XCTAssertFalse(
            MatrixNativeRetryContract.permitsManualRetry(
                for: .text,
                hasLiveSendHandle: false
            )
        )
        for kind in [
            MatrixNativeDeliveryKind.attachment,
            .poll,
            .sticker,
        ] {
            XCTAssertFalse(
                MatrixNativeRetryContract.permitsManualRetry(
                    for: kind,
                    hasLiveSendHandle: false
                )
            )
        }
        XCTAssertEqual(
            MatrixNativeRetryContract.owner(for: .attachment, hasLiveSendHandle: false),
            .matrixSDKQueue
        )
        XCTAssertEqual(
            MatrixNativeRetryContract.owner(for: .poll, hasLiveSendHandle: false),
            .matrixSDKQueue
        )
        XCTAssertEqual(
            MatrixNativeRetryContract.owner(for: .sticker, hasLiveSendHandle: false),
            .oneShotFailClosed
        )
    }
}
