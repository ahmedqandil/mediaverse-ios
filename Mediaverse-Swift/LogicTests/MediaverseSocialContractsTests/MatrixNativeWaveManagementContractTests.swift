import XCTest
@testable import MediaverseSocialContracts

final class MatrixNativeWaveManagementContractTests: XCTestCase {
    func testStrongestModelPromptRemainsNormative() {
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normativeSource,
            "User strongest-model Matrix-native Vibes prompt (precedence 1)"
        )
    }

    func testProfileNormalizationIsBoundedAndRejectsEmptyName() {
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normalizedProfile(
                name: "  Cinema  ",
                topic: "  New releases  "
            )?.name,
            "Cinema"
        )
        XCTAssertNil(
            MatrixNativeWaveManagementContract.normalizedProfile(
                name: " \n ",
                topic: "Topic"
            )
        )
        XCTAssertNil(
            MatrixNativeWaveManagementContract.normalizedProfile(
                name: String(
                    repeating: "a",
                    count: MatrixNativeWaveManagementContract.maximumNameLength + 1
                ),
                topic: ""
            )
        )
    }

    func testSearchRequiresBoundedMeaningfulQuery() {
        XCTAssertNil(MatrixNativeWaveManagementContract.normalizedSearch(" a "))
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normalizedSearch("  matrix  "),
            "matrix"
        )
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normalizedSearch("  cafe\u{301}\n عربي  "),
            "café عربي"
        )
        XCTAssertNil(
            MatrixNativeWaveManagementContract.normalizedSearch(
                String(
                    repeating: "x",
                    count: MatrixNativeWaveManagementContract.maximumSearchLength + 1
                )
            )
        )
    }

    func testSearchResultsDeduplicateByWaveAndEvent() {
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.uniqueSearchResultOffsets([
                ("!one:example.org", "$event"),
                ("!one:example.org", "$event"),
                ("!two:example.org", "$event"),
            ]),
            [0, 2]
        )
    }

    func testCreatorCurrentUserAndServiceIdentityCannotBeManaged() {
        XCTAssertFalse(
            MatrixNativeWaveManagementContract.mayManage(
                isCurrentUser: true,
                isService: false,
                role: .administrator
            )
        )
        XCTAssertFalse(
            MatrixNativeWaveManagementContract.mayManage(
                isCurrentUser: false,
                isService: true,
                role: .member
            )
        )
        XCTAssertFalse(
            MatrixNativeWaveManagementContract.mayManage(
                isCurrentUser: false,
                isService: false,
                role: .creator
            )
        )
        XCTAssertTrue(
            MatrixNativeWaveManagementContract.mayManage(
                isCurrentUser: false,
                isService: false,
                role: .member
            )
        )
    }

    func testRolePowerLevelsAreExplicitAndCreatorIsImmutable() {
        XCTAssertNil(MatrixNativeWaveManagementContract.powerLevel(.creator))
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.powerLevel(.administrator),
            100
        )
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.powerLevel(.moderator),
            50
        )
        XCTAssertEqual(MatrixNativeWaveManagementContract.powerLevel(.member), 0)
    }

    func testModerationReasonIsOptionalNormalizedAndPrivacyBounded() {
        XCTAssertNil(
            MatrixNativeWaveManagementContract.normalizedModerationReason(" \n ")
        )
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normalizedModerationReason(
                "  Repeated spam  "
            ),
            "Repeated spam"
        )
        XCTAssertEqual(
            MatrixNativeWaveManagementContract.normalizedModerationReason(
                String(
                    repeating: "x",
                    count: MatrixNativeWaveManagementContract
                        .maximumModerationReasonLength + 10
                )
            )?.count,
            MatrixNativeWaveManagementContract.maximumModerationReasonLength
        )
    }
}
