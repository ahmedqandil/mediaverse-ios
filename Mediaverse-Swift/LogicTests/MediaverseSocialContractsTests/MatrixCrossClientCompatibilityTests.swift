import XCTest
@testable import MediaverseSocialContracts

final class MatrixCrossClientCompatibilityTests: XCTestCase {
    func testUsesTheExactWebSwiftCustomEventIntersection() {
        XCTAssertEqual(MatrixCrossClientCompatibility.customEventTypes, [
            "com.westreem.share.v1",
            "com.westreem.event_ref.v1",
            "com.westreem.room.rules.v1",
            "com.westreem.live.speaker.v1",
            "com.westreem.live.stage.v1",
            "com.westreem.public_sharing.v1",
            "com.westreem.watch_party.v1",
        ])
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "com.westreem.live.stage.v1"),
            .crossClientCustom
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "com.westreem.watch_party.state.v1"),
            .preserveHidden
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "com.westreem.public_sharing.v1"),
            .crossClientCustom
        )
    }

    func testPreservesUnknownEventsWithoutInterpretingThemAsContent() {
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "com.example.future.v9"),
            .preserveHidden
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "m.room.message"),
            .nativeMatrix
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.disposition(for: "bad event type"),
            .reject
        )
    }

    func testCanonicalizesVibesAndMatrixToLinksToOneTarget() {
        let expected = MatrixCrossClientDeepLinkTarget(
            roomID: "!wave:example.org",
            eventID: "$event:example.org"
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.resolveDeepLink(
                "/vibes/rooms/%21wave%3Aexample.org?event=%24event%3Aexample.org"
            ),
            expected
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.resolveDeepLink(
                "https://matrix.to/#/%21wave%3Aexample.org/%24event%3Aexample.org?via=example.org"
            ),
            expected
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.resolveDeepLink(
                "https://westreem.com/vibes/rooms/%21wave%3Aexample.org?event=%24event%3Aexample.org"
            ),
            expected
        )
        XCTAssertEqual(
            MatrixCrossClientCompatibility.resolveDeepLink(
                "westreem://vibes/rooms/%21wave%3Aexample.org?event=%24event%3Aexample.org"
            ),
            expected
        )
    }

    func testRejectsDoubleEncodedMalformedAndForeignLinks() {
        XCTAssertNil(MatrixCrossClientCompatibility.resolveDeepLink(
            "/vibes/rooms/%2521wave%253Aexample.org"
        ))
        XCTAssertNil(MatrixCrossClientCompatibility.resolveDeepLink(
            "/vibes/rooms/%21wave%3Aexample.org?event=%2524event%253Aexample.org"
        ))
        XCTAssertNil(MatrixCrossClientCompatibility.resolveDeepLink(
            "/vibes/rooms/%21wave%3Aexample.org?event=not-an-event"
        ))
        XCTAssertNil(MatrixCrossClientCompatibility.resolveDeepLink(
            "https://example.org/#/%21wave%3Aexample.org"
        ))
        XCTAssertNil(MatrixCrossClientCompatibility.resolveDeepLink(
            "https://matrix.to.evil.example/#/%21wave%3Aexample.org"
        ))
    }
}
