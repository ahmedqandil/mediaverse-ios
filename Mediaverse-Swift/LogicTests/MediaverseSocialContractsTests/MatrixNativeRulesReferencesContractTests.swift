import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeRulesReferencesContractTests: XCTestCase {
    func testWaveRulesUseVersionedCanonicalMatrixStateSchema() throws {
        XCTAssertEqual(
            MatrixNativeWaveRulesContract.eventType,
            "com.westreem.room.rules.v1"
        )
        let state = MatrixNativeWaveRulesState(
            revision: 3,
            rules: [
                MatrixNativeWaveRule(
                    id: "be-kind",
                    text: "Be kind and discuss the work, not the person.",
                    locale: "en",
                    order: 0
                ),
                MatrixNativeWaveRule(
                    id: "no-spam",
                    text: "Do not post spam.",
                    order: 1
                ),
            ],
            updatedAt: "2026-07-29T12:00:00Z",
            updatedByWestreemUserID: "immutable-user-id"
        )

        let encoded = try MatrixNativeWaveRulesContract.encode(state)
        let decoded = try MatrixNativeWaveRulesContract.decode(contentJSON: encoded)
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(encoded.contains(#""schema_version":1"#))
        XCTAssertTrue(encoded.contains(#""updated_by_westreem_user_id""#))
    }

    func testWaveRulesRejectDuplicateIdentityOrderAndOversizedContent() {
        let base = MatrixNativeWaveRule(id: "one", text: "First", order: 0)
        XCTAssertThrowsError(
            try MatrixNativeWaveRulesContract.validate(
                MatrixNativeWaveRulesState(
                    revision: 1,
                    rules: [base, base],
                    updatedAt: "2026-07-29T12:00:00Z",
                    updatedByWestreemUserID: "user"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? MatrixNativeWaveRulesValidationError,
                .duplicateRuleID
            )
        }

        XCTAssertThrowsError(
            try MatrixNativeWaveRulesContract.validate(
                MatrixNativeWaveRulesState(
                    revision: 1,
                    rules: [
                        base,
                        MatrixNativeWaveRule(id: "two", text: "Second", order: 0),
                    ],
                    updatedAt: "2026-07-29T12:00:00Z",
                    updatedByWestreemUserID: "user"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? MatrixNativeWaveRulesValidationError,
                .duplicateRuleOrder
            )
        }

        XCTAssertThrowsError(
            try MatrixNativeWaveRulesContract.validate(
                MatrixNativeWaveRulesState(
                    revision: 1,
                    rules: [
                        MatrixNativeWaveRule(
                            id: "long",
                            text: String(repeating: "x", count: 1_001),
                            order: 0
                        ),
                    ],
                    updatedAt: "2026-07-29T12:00:00Z",
                    updatedByWestreemUserID: "user"
                )
            )
        )
    }

    func testEventsRequireDedicatedTypedEventReference() throws {
        let content = referenceJSON(entityType: "event")
        let event = try MatrixNativeWestreemReferenceContract.decode(
            eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
            contentJSON: content
        )
        XCTAssertEqual(event.entityType, "event")
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceContract.decode(
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                contentJSON: content
            )
        )
    }

    func testResolvedEnvelopeRejectsWrongAuthorityAndEventType() throws {
        let event = try MatrixNativeWestreemReferenceContract.decode(
            eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
            contentJSON: referenceJSON(entityType: "event")
        )
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceEnvelope(
                authority: "WESTREEM",
                eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
                content: event
            )
        )
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceEnvelope(
                authority: "MATRIX",
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                content: event
            )
        )
        XCTAssertNoThrow(
            try MatrixNativeWestreemReferenceEnvelope(
                authority: "MATRIX",
                eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
                content: event
            )
        )
    }

    func testReferenceEncodingRoundTripsAndPreservesTypedEventBoundary() throws {
        let event = try MatrixNativeWestreemReferenceContract.decode(
            eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
            contentJSON: referenceJSON(entityType: "event")
        )
        let encoded = try MatrixNativeWestreemReferenceContract.encode(
            eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
            value: event
        )
        XCTAssertEqual(
            try MatrixNativeWestreemReferenceContract.decode(
                eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
                contentJSON: encoded
            ),
            event
        )
    }

    func testReferenceThumbnailMustBeSafeWestreemOrMXC() throws {
        for thumbnail in [
            "https://www.westreem.com/api/image-proxy?url=asset",
            "mxc://vibes.westreem.com/media-id",
        ] {
            let json = referenceJSON(entityType: "video")
                .replacingOccurrences(
                    of: #""summary": "A public Westreem event.","#,
                    with: #""summary": "A public Westreem event.", "thumbnail": "\#(thumbnail)","#
                )
            XCTAssertNoThrow(
                try MatrixNativeWestreemReferenceContract.decode(
                    eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                    contentJSON: json
                )
            )
        }

        let unsafe = referenceJSON(entityType: "video")
            .replacingOccurrences(
                of: #""summary": "A public Westreem event.","#,
                with: #""summary": "A public Westreem event.", "thumbnail": "https://evil.example/image.jpg","#
            )
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceContract.decode(
                eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                contentJSON: unsafe
            )
        )
    }

    func testNonEventSharesUseGenericTypedShareEvent() throws {
        let video = try MatrixNativeWestreemReferenceContract.decode(
            eventType: MatrixNativeWestreemReferenceContract.shareEventType,
            contentJSON: referenceJSON(entityType: "video")
        )
        XCTAssertEqual(video.entityType, "video")
        XCTAssertThrowsError(
            try MatrixNativeWestreemReferenceContract.decode(
                eventType: MatrixNativeWestreemReferenceContract.eventReferenceType,
                contentJSON: referenceJSON(entityType: "video")
            )
        )
    }

    func testReferenceURLsFailClosedOutsideWestreem() {
        XCTAssertNotNil(
            MatrixNativeWestreemReferenceContract.safeWestreemURL(
                "https://www.westreem.com/events/event-1"
            )
        )
        for value in [
            "http://www.westreem.com/events/event-1",
            "https://westreem.com.evil.example/events/event-1",
            "https://user:secret@westreem.com/events/event-1",
            "https://westreem.com/events/event-1#fragment",
        ] {
            XCTAssertNil(
                MatrixNativeWestreemReferenceContract.safeWestreemURL(value),
                value
            )
        }
    }

    func testNativeUISliceClaimsRulesAndTypedEventReferences() {
        XCTAssertTrue(
            MatrixNativeVibesUIContract.required.contains(.structuredWaveRules)
        )
        XCTAssertTrue(
            MatrixNativeVibesUIContract.required.contains(
                .typedWestreemEventReferences
            )
        )
    }

    private func referenceJSON(entityType: String) -> String {
        """
        {
          "schema_version": 1,
          "entity_type": "\(entityType)",
          "entity_id": "event-1",
          "canonical_url": "https://www.westreem.com/events/event-1",
          "title": "Westreem Premiere",
          "summary": "A public Westreem event.",
          "provenance": {
            "source_product": "westreem",
            "actor_westreem_user_id": "immutable-user-id"
          },
          "idempotency_key": "share:event:event-1"
        }
        """
    }
}
