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
}
