import XCTest
@testable import MediaverseSocialContracts

final class MatrixAttachmentStorageMigrationContractTests: XCTestCase {
    func testEveryAttachmentTypeRemainsOwnedByMatrixRustSDK() {
        for kind in MatrixAttachmentStorageMigrationContract.AttachmentKind.allCases {
            XCTAssertTrue(
                MatrixAttachmentStorageMigrationContract.requiresSDKAttachmentAPI(for: kind),
                "\(kind) must remain on the standard Matrix SDK attachment path"
            )
        }
        XCTAssertEqual(
            MatrixAttachmentStorageMigrationContract.uploadProgressOwner,
            .matrixRustSDK
        )
        XCTAssertEqual(
            MatrixAttachmentStorageMigrationContract.retryOwner,
            .matrixRustSDK
        )
    }

    func testOnlyCanonicalMXCIdentityMayBePersistedInEvents() {
        XCTAssertTrue(
            MatrixAttachmentStorageMigrationContract.acceptsPersistedMediaURL(
                "mxc://vibes.westreem.com/media-id_123"
            )
        )
        for rejected in [
            "https://cdn.example/media-id",
            "https://example.r2.cloudflarestorage.com/object?signature=secret",
            "mxc://vibes.westreem.com/",
            "mxc:///media-id",
            "mxc://vibes.westreem.com/path/extra",
            "mxc://vibes.westreem.com/media id",
            "mxc://vibes.westreem.com/media-id?token=secret",
        ] {
            XCTAssertFalse(
                MatrixAttachmentStorageMigrationContract.acceptsPersistedMediaURL(rejected),
                rejected
            )
        }
    }

    func testFirstSliceForbidsDirectCloudflareAndClientTranscoding() {
        XCTAssertFalse(MatrixAttachmentStorageMigrationContract.permitsDirectCloudflareUpload)
        XCTAssertFalse(MatrixAttachmentStorageMigrationContract.permitsClientTranscoding)
    }
}
