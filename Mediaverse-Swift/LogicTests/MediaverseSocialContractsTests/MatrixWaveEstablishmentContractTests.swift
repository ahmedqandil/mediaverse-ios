import XCTest
@testable import MediaverseSocialContracts

final class MatrixWaveEstablishmentContractTests: XCTestCase {
    private let roomID = "!wave:example.org"
    private let parentSpaceID = "!vibe:example.org"
    private let serviceUserID = "@westreem_service:example.org"
    private let markerEventID = "$marker"

    func testCanonicalBytesMatchTheSharedCrossClientVector() {
        let manifest = manifest(
            bootstrapEventIDs: ["$b", "$a"],
            manifestHash: String(repeating: "0", count: 64)
        )

        let canonical = MatrixWaveEstablishmentContract.canonical(manifest)
        XCTAssertEqual(
            canonical,
            "westreem-wave-establishment\n1\n!wave:example.org\n!vibe:example.org\n$a\n$b"
        )
        XCTAssertEqual(
            MatrixWaveEstablishmentContract.sha256Hex(canonical),
            "cffb901c0e5a63ff7074f5c4184dbadc832d15c2e64c3273b5d9a4da4cd311ae"
        )
    }

    func testCanonicalOrderingUsesUnsignedUTF8Bytes() {
        let manifest = manifest(
            bootstrapEventIDs: ["$😀", "$�"],
            manifestHash: String(repeating: "0", count: 64)
        )
        let canonical = MatrixWaveEstablishmentContract.canonical(manifest)
        XCTAssertTrue(canonical.hasSuffix("\n$�\n$😀"))
        XCTAssertEqual(
            MatrixWaveEstablishmentContract.sha256Hex(canonical),
            "03e960f6207b01a15d0c1d785e0f80a3ffa7eb5ade2d8c8611e1a44684824fd5"
        )
    }

    func testValidTrustedMarkerSuppressesOnlyMarkerAndProvenBootstrapIDs() throws {
        let projection = try XCTUnwrap(verify())

        XCTAssertEqual(projection.manifest.bootstrapEventIDs, ["$a", "$b"])
        XCTAssertEqual(projection.suppressedEventIDs, ["$marker", "$a", "$b"])
        XCTAssertFalse(projection.permitsProjection(of: "$marker"))
        XCTAssertFalse(projection.permitsProjection(of: "$a"))
        XCTAssertTrue(projection.permitsProjection(of: "$later"))
        XCTAssertTrue(projection.cacheKey.contains(projection.manifest.manifestHash))
    }

    func testAuthoritativeCurrentStateProjectionWorksWithoutTimelineMarker() throws {
        let marker = MatrixWaveAuthoritativeStateEvent(
            roomID: roomID,
            eventID: markerEventID,
            sender: serviceUserID,
            type: MatrixWaveEstablishmentContract.eventType,
            stateKey: "",
            contentJSON: try validContent()
        )
        let parent = MatrixWaveAuthoritativeParent(
            spaceRoomID: parentSpaceID,
            parentEvent: MatrixWaveAuthoritativeStateEvent(
                roomID: roomID,
                eventID: "$parent",
                sender: "@owner:example.org",
                type: "m.space.parent",
                stateKey: parentSpaceID,
                contentJSON: #"{"canonical":true,"via":["example.org"]}"#
            ),
            childEvent: MatrixWaveAuthoritativeStateEvent(
                roomID: parentSpaceID,
                eventID: "$child",
                sender: "@owner:example.org",
                type: "m.space.child",
                stateKey: roomID,
                contentJSON: #"{"via":["example.org"]}"#
            )
        )
        let state = MatrixWaveAuthoritativeState(
            roomID: roomID,
            marker: marker,
            parents: [parent]
        )
        let projection = MatrixWaveEstablishmentContract.verify(
            authoritative: state,
            roomID: roomID,
            trustedServiceUserID: serviceUserID
        )
        XCTAssertEqual(projection?.suppressedEventIDs, ["$a", "$b", "$marker"])
        XCTAssertNil(
            MatrixWaveEstablishmentContract.verify(
                authoritative: MatrixWaveAuthoritativeState(
                    roomID: roomID,
                    marker: marker,
                    parents: [
                        MatrixWaveAuthoritativeParent(
                            spaceRoomID: parentSpaceID,
                            parentEvent: parent.parentEvent,
                            childEvent: MatrixWaveAuthoritativeStateEvent(
                                roomID: parentSpaceID,
                                eventID: "$child2",
                                sender: "@owner:example.org",
                                type: "m.space.child",
                                stateKey: roomID,
                                contentJSON: #"{"via":[]}"#
                            )
                        )
                    ]
                ),
                roomID: roomID,
                trustedServiceUserID: serviceUserID
            )
        )
    }

    func testMissingAuthorityOrHierarchyFailsOpen() {
        XCTAssertNil(verify(senderID: "@moderator:example.org"))
        XCTAssertNil(verify(stateKey: "not-empty"))
        XCTAssertNil(verify(canonicalParentSpaceIDs: []))
        XCTAssertNil(verify(hasCanonicalReciprocalParentEdge: false))
        XCTAssertNil(verify(markerEventID: "not-an-event"))
    }

    func testMalformedOrReboundManifestFailsOpen() throws {
        let valid = try validContent()
        let base = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any]
        )

        var extra = base
        extra["creation_transaction_id"] = "forbidden"
        XCTAssertNil(verify(contentJSON: json(extra)))

        var wrongRoom = base
        wrongRoom["room_id"] = "!other:example.org"
        XCTAssertNil(verify(contentJSON: json(wrongRoom)))

        var wrongParent = base
        wrongParent["parent_space_id"] = "!other-vibe:example.org"
        XCTAssertNil(verify(contentJSON: json(wrongParent)))

        var uppercaseHash = base
        uppercaseHash["manifest_hash"] = String(repeating: "A", count: 64)
        XCTAssertNil(verify(contentJSON: json(uppercaseHash)))

        var duplicateIDs = base
        duplicateIDs["bootstrap_event_ids"] = ["$a", "$a"]
        XCTAssertNil(verify(contentJSON: json(duplicateIDs)))

        var emptyIDs = base
        emptyIDs["bootstrap_event_ids"] = []
        XCTAssertNil(verify(contentJSON: json(emptyIDs)))

        var tooManyIDs = base
        tooManyIDs["bootstrap_event_ids"] = (0...64).map { "$\($0)" }
        XCTAssertNil(verify(contentJSON: json(tooManyIDs)))
    }

    func testCanonicalParentContentRequiresExplicitBooleanTrue() {
        XCTAssertTrue(
            MatrixWaveEstablishmentContract.isCanonicalParentContent(
                #"{"canonical":true,"via":["example.org"]}"#
            )
        )
        for invalid in [
            #"{}"#,
            #"{"canonical":false}"#,
            #"{"canonical":"true"}"#,
            #"[]"#,
        ] {
            XCTAssertFalse(
                MatrixWaveEstablishmentContract.isCanonicalParentContent(invalid)
            )
        }
    }

    func testVAC002ProjectionFlagsRemainExactAcrossClients() {
        XCTAssertEqual(
            MatrixWaveEventEligibility.policy(for: .messageLike),
            MatrixWaveEventEligibility(
                displayInTimeline: true,
                displayAsCompactRoomEvent: false,
                updatesPreview: true,
                updatesRecency: true,
                countsUnread: true,
                eligibleForPush: true,
                eligibleForSearch: true
            )
        )
        XCTAssertEqual(
            MatrixWaveEventEligibility.policy(for: .recognizedRoomState),
            MatrixWaveEventEligibility(
                displayInTimeline: true,
                displayAsCompactRoomEvent: true,
                updatesPreview: false,
                updatesRecency: false,
                countsUnread: false,
                eligibleForPush: false,
                eligibleForSearch: false
            )
        )
        let hidden = MatrixWaveEventEligibility(
            displayInTimeline: false,
            displayAsCompactRoomEvent: false,
            updatesPreview: false,
            updatesRecency: false,
            countsUnread: false,
            eligibleForPush: false,
            eligibleForSearch: false
        )
        XCTAssertEqual(
            MatrixWaveEventEligibility.policy(for: .establishmentOrBootstrap),
            hidden
        )
        XCTAssertEqual(
            MatrixWaveEventEligibility.policy(for: .unsupportedOrProtocolMetadata),
            hidden
        )
    }

    private func verify(
        contentJSON: String? = nil,
        markerEventID: String? = nil,
        stateKey: String = "",
        senderID: String? = nil,
        canonicalParentSpaceIDs: Set<String>? = nil,
        hasCanonicalReciprocalParentEdge: Bool = true
    ) -> MatrixWaveEstablishmentProjection? {
        MatrixWaveEstablishmentContract.verify(
            contentJSON: contentJSON ?? (try! validContent()),
            markerEventID: markerEventID ?? self.markerEventID,
            stateKey: stateKey,
            senderID: senderID ?? serviceUserID,
            trustedServiceUserID: serviceUserID,
            roomID: roomID,
            canonicalParentSpaceIDs: canonicalParentSpaceIDs ?? [parentSpaceID],
            hasCanonicalReciprocalParentEdge: { _ in
                hasCanonicalReciprocalParentEdge
            }
        )
    }

    private func validContent() throws -> String {
        let unsigned = manifest(
            bootstrapEventIDs: ["$b", "$a"],
            manifestHash: String(repeating: "0", count: 64)
        )
        return json([
            "version": unsigned.version,
            "hash_algorithm": unsigned.hashAlgorithm,
            "manifest_hash": MatrixWaveEstablishmentContract.sha256Hex(
                MatrixWaveEstablishmentContract.canonical(unsigned)
            ),
            "room_id": unsigned.roomID,
            "parent_space_id": unsigned.parentSpaceID,
            "bootstrap_event_ids": unsigned.bootstrapEventIDs,
        ])
    }

    private func manifest(
        bootstrapEventIDs: [String],
        manifestHash: String
    ) -> MatrixWaveEstablishmentManifest {
        MatrixWaveEstablishmentManifest(
            version: 1,
            hashAlgorithm: "sha256",
            manifestHash: manifestHash,
            roomID: roomID,
            parentSpaceID: parentSpaceID,
            bootstrapEventIDs: bootstrapEventIDs
        )
    }

    private func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
