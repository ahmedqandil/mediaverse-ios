import XCTest
@testable import MediaverseEventContracts

final class EventContractDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testListFixtureToleratesAdditiveFieldsAndSafeDefaults() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "event-list-additive",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let response = try decoder.decode(VibeEventListResponse.self, from: Data(contentsOf: url))
        let event = try XCTUnwrap(response.events.first)

        XCTAssertEqual(event.summary, "")
        XCTAssertEqual(event.endsAt, event.startsAt)
        XCTAssertEqual(event.timeZone, "UTC")
        XCTAssertEqual(event.status, "SCHEDULED")
        XCTAssertEqual(event.goingCount, 0)
        XCTAssertNil(response.nextCursor)
    }

    func testMissingEventsDecodesAsEmptyPage() throws {
        let response = try decoder.decode(
            VibeEventListResponse.self,
            from: Data(#"{"nextCursor":null}"#.utf8)
        )
        XCTAssertTrue(response.events.isEmpty)
    }

    func testCapabilitiesDefaultToDenied() throws {
        let value = try decoder.decode(VibeEventCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(value.canManage)
        XCTAssertFalse(value.canRsvp)
        XCTAssertFalse(value.canShare)
        XCTAssertFalse(value.canJoin)
        XCTAssertFalse(value.joinWindowOpen)
        XCTAssertEqual(value.joinWindowState, "unavailable")
    }

    func testAgendaAcceptsLegacyStringAndObject() throws {
        let values = try decoder.decode(
            [VibeEventAgendaItem].self,
            from: Data(#"["Doors open",{"id":"qa","title":"Q&A"}]"#.utf8)
        )
        XCTAssertEqual(values.map(\.title), ["Doors open", "Q&A"])
    }

    func testReminderDefaultsAdditiveDeliveryFields() throws {
        let reminder = try decoder.decode(
            VibeEventReminder.self,
            from: Data(#"{"id":"r1","futureChannelMetadata":true}"#.utf8)
        )
        XCTAssertEqual(reminder.leadMinutes, 15)
        XCTAssertEqual(reminder.channel, "push")
    }

    func testEventRealtimeExperienceIsAdditiveAndFailsClosed() throws {
        let response = try decoder.decode(
            VibeEventListResponse.self,
            from: Data(
                """
                {"events":[
                  {"id":"legacy","slug":"legacy","title":"Legacy","startsAt":"2026-08-01T10:00:00Z",
                   "club":{"name":"Vibe"}},
                  {"id":"live","slug":"live","title":"Live","startsAt":"2026-08-02T10:00:00Z",
                   "club":{"name":"Vibe"},"realtimeExperience":{
                     "transport":"MATRIX","schemaVersion":1,"roomMode":"DEDICATED_RSVP",
                     "liveMode":"WATCH_PARTY","provisioningStatus":"READY",
                     "conversationEnabled":true,"presenceEnabled":true,
                     "voiceLoungeEnabled":true,"watchPartyEnabled":true
                   }}
                ]}
                """.utf8
            )
        )

        XCTAssertNil(response.events[0].realtimeExperience)
        let realtime = try XCTUnwrap(response.events[1].realtimeExperience)
        XCTAssertTrue(realtime.isMatrixReady)
        XCTAssertTrue(realtime.conversationEnabled)
        XCTAssertTrue(realtime.watchPartyEnabled)

        let pending = try decoder.decode(
            VibeEventRealtimeExperience.self,
            from: Data(#"{"transport":"MATRIX","schemaVersion":1}"#.utf8)
        )
        XCTAssertFalse(pending.isMatrixReady)
        XCTAssertFalse(pending.presenceEnabled)
    }

    func testEventLiveControllerPreservesWestreemPlayerAuthority() throws {
        let response = try decoder.decode(
            EventLiveControllerResponse.self,
            from: Data(
                """
                {"controller":{
                  "watchParty":{"playbackEpoch":"epoch-1","sequence":"9","playbackState":"PLAYING",
                    "positionMs":4200,"serverTimestamp":"2026-07-29T10:00:00Z"},
                  "participant":{"inAdBreak":true,"needsRejoin":false},
                  "liveRoom":{"provider":"LIVEKIT","configured":true,"signallingStatus":"READY",
                    "stageLocked":false,"emergencyEnded":false},
                  "capabilities":{"canControlPlayback":true,"canModerateStage":false,"canRequestSpeaker":true},
                  "playerAuthority":{"delivery":"WESTREEM","entitlement":"WESTREEM","ads":"PER_CLIENT",
                    "analytics":"WESTREEM","matrixRole":"SYNC_AND_SIGNALLING_ONLY"}
                }}
                """.utf8
            )
        )
        XCTAssertEqual(response.controller.watchReadiness, .ready)
        XCTAssertTrue(response.controller.playerAuthority.westreemOwnsPlayback)
        XCTAssertEqual(response.controller.liveRoom?.readiness, .ready)
        XCTAssertTrue(response.controller.participant?.inAdBreak == true)
    }

    func testEventLiveControllerFailsClosedWhenAuthorityDoesNotMatch() throws {
        let response = try decoder.decode(
            EventLiveControllerResponse.self,
            from: Data(
                """
                {"controller":{"watchParty":null,"participant":null,"liveRoom":null,
                  "speakerRequest":null,"capabilities":{},
                  "playerAuthority":{"delivery":"MATRIX","entitlement":"WESTREEM","ads":"PER_CLIENT",
                    "analytics":"WESTREEM","matrixRole":"SYNC_AND_SIGNALLING_ONLY"}}}
                """.utf8
            )
        )
        XCTAssertEqual(response.controller.watchReadiness, .unavailable)
        XCTAssertFalse(response.controller.capabilities.canControlPlayback)
    }
}
