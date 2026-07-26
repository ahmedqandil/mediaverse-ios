import XCTest
@testable import MediaverseSocialContracts

final class LegacySocialAPIAdapterTests: XCTestCase {
    func testAtmosphereUsesFrozenBareArrayEndpointAndFiltersWebExcludedMedia() async throws {
        let transport = SocialTransportStub(responses: [
            "/api/subscriptions/feed": """
            [
              {"_kind":"fan_club_post","id":"r1","clubId":"v1","createdAt":"2026-07-26T00:00:00Z","author":{"id":"u1"}},
              {"_kind":"video","id":"v1","title":"Video","views":1,"type":"video","createdAt":"2026-07-26T00:00:00Z"},
              {"_kind":"video","id":"s1","title":"Short","views":1,"type":"short","createdAt":"2026-07-26T00:00:00Z"},
              {"_kind":"episode","id":"e1","title":"Episode","views":1,"type":"episode","createdAt":"2026-07-26T00:00:00Z"}
            ]
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let result = try await adapter.atmosphere()

        XCTAssertEqual(result.items.count, 2)
        let paths = await transport.paths
        XCTAssertEqual(paths, ["/api/subscriptions/feed"])
    }

    func testDiscoverTreatsCursorAsOpaqueAndClampsLimit() async throws {
        let expected = "/api/fan-clubs/discover?mode=TRENDING&limit=40&cursor=opaque%2B%2F%3D&author=ahmed&profileTab=ECHOED"
        let transport = SocialTransportStub(responses: [
            expected: #"{"version":1,"mode":"TRENDING","posts":[],"nextCursor":null}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        _ = try await adapter.discover(
            mode: .trending,
            cursor: "opaque+/=",
            limit: 100,
            authorHandle: "@ahmed",
            profileTab: .echoed
        )

        let paths = await transport.paths
        XCTAssertEqual(paths, [expected])
    }

    func testVibeSlugIsEncodedAsOnePathSegment() async throws {
        let expected = "/api/fan-clubs/film%20fans"
        let transport = SocialTransportStub(responses: [
            expected: """
            {
              "club":{"id":"v1","slug":"film fans","name":"Film Fans"},
              "capabilities":{"canView":true,"canViewContent":true},
              "membership":null,
              "following":false
            }
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let response = try await adapter.vibe(slug: "film fans")

        XCTAssertEqual(response.club.id, "v1")
        let paths = await transport.paths
        XCTAssertEqual(paths, [expected])
    }

    func testMyVibesPreservesIDCursorAndClampsLimit() async throws {
        let expected = "/api/fan-clubs?mine=1&limit=1&cursor=id-2"
        let transport = SocialTransportStub(responses: [
            expected: #"{"clubs":[],"nextCursor":null}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        _ = try await adapter.myVibes(cursor: "id-2", limit: 0)

        let paths = await transport.paths
        XCTAssertEqual(paths, [expected])
    }
}

private actor SocialTransportStub: LegacySocialTransport {
    private let responses: [String: String]
    private(set) var paths: [String] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func socialData(path: String) async throws -> Data {
        paths.append(path)
        guard let response = responses[path] else {
            throw StubError.missing(path)
        }
        return Data(response.utf8)
    }

    enum StubError: Error {
        case missing(String)
    }
}
