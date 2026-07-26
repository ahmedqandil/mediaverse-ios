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

    func testAddEnergyUsesExactLegacyEndpointAndSanitizedBody() async throws {
        let path = "/api/fan-club-posts/ripple%2Fone/rating"
        let transport = SocialTransportStub(responses: [
            path: #"{"overall":4,"tags":["DEEP","REAL"],"review":null}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let result = try await adapter.addEnergy(
            toRipple: "ripple/one",
            overall: 4,
            tags: [" REAL ", "DEEP", "REAL", ""]
        )

        XCTAssertEqual(result.overall, 4)
        let postPaths = await transport.postPaths
        let postBodies = await transport.postBodies
        XCTAssertEqual(postPaths, [path])
        let body = try XCTUnwrap(postBodies.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["overall"] as? Int, 4)
        XCTAssertEqual(object["tags"] as? [String], ["DEEP", "REAL"])
    }

    func testPollVoteAndShareKeepEndpointSpecificEnvelopes() async throws {
        let pollPath = "/api/fan-club-polls/poll-1/vote"
        let pollTransport = SocialTransportStub(responses: [
            pollPath: """
            {"poll":{"id":"poll-1","question":"Pick","allowsMultiple":false,
            "maxSelections":1,"resultsVisibility":"AFTER_VOTE",
            "options":[{"id":"a","label":"A","voteCount":2}],"votes":[{"optionId":"a"}]}}
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: pollTransport)
        let vote = try await adapter.vote(inPoll: "poll-1", optionIds: ["a"])
        XCTAssertEqual(vote.poll.votes.first?.optionId, "a")
        let pollPostPaths = await pollTransport.postPaths
        XCTAssertEqual(pollPostPaths, [pollPath])

        let sharePath = "/api/fan-club-posts/ripple-1/share"
        let shareTransport = SocialTransportStub(responses: [
            sharePath: #"{"shareCount":7}"#
        ])
        let shareAdapter = LegacySocialAPIAdapter(transport: shareTransport)
        let share = try await shareAdapter.recordShare(
            ofRipple: "ripple-1",
            channel: .native
        )
        XCTAssertEqual(share.shareCount, 7)
        let sharePostPaths = await shareTransport.postPaths
        XCTAssertEqual(sharePostPaths, [sharePath])
    }
}

private actor SocialTransportStub: LegacySocialTransport {
    private let responses: [String: String]
    private(set) var paths: [String] = []
    private(set) var postPaths: [String] = []
    private(set) var postBodies: [Data] = []

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

    func socialPostData(path: String, body: Data) async throws -> Data {
        postPaths.append(path)
        postBodies.append(body)
        guard let response = responses[path] else {
            throw StubError.missing(path)
        }
        return Data(response.utf8)
    }

    enum StubError: Error {
        case missing(String)
    }
}
