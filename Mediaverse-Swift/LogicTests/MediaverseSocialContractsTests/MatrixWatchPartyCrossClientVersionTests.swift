import XCTest
@testable import MediaverseSocialContracts

final class MatrixWatchPartyCrossClientVersionTests: XCTestCase {
    func testWebTransferredHostOverridesLegacyStarter() {
        XCTAssertEqual(
            MatrixWatchPartyCrossClientVersion.controllingUserID(
                host: "@new:example.org",
                startedBy: "@original:example.org"
            ),
            "@new:example.org"
        )
        XCTAssertEqual(
            MatrixWatchPartyCrossClientVersion.controllingUserID(
                host: nil,
                startedBy: "@legacy:example.org"
            ),
            "@legacy:example.org"
        )
    }

    func testSequenceIsMonotonicAndFailsClosedAtOverflow() {
        XCTAssertEqual(MatrixWatchPartyCrossClientVersion.nextSequence(after: nil), 1)
        XCTAssertEqual(MatrixWatchPartyCrossClientVersion.nextSequence(after: 41), 42)
        XCTAssertNil(MatrixWatchPartyCrossClientVersion.nextSequence(after: Int64.max))
    }

    func testSwiftEpochIsBoundedToNonnegativeComponents() {
        XCTAssertEqual(
            MatrixWatchPartyCrossClientVersion.playbackEpoch(
                nowMilliseconds: -1,
                sequence: -1
            ),
            "swift_0_0"
        )
    }
}
