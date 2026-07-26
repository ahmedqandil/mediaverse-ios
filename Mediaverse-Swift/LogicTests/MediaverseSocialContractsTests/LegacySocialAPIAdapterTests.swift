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

    func testRippleCommentsReuseFrozenCommentEndpointsAndPreserveReplies() async throws {
        let listPath = "/api/fan-club-posts/ripple-1/comments"
        let createPath = listPath
        let likePath = "/api/fan-club-comments/comment-1/like"
        let payload = """
        {"comments":[{
          "id":"comment-1","userId":"user-1","content":"Top level",
          "contentHtml":"Top level","parentId":null,"likeCount":2,
          "createdAt":"2026-07-26T10:00:00Z",
          "user":{"id":"user-1","name":"Ahmed","handle":"ahmed"},
          "likes":[{"id":"like-1"}],
          "replies":[{
            "id":"reply-1","userId":"user-2","content":"Reply",
            "parentId":"comment-1","createdAt":"2026-07-26T10:01:00Z",
            "user":{"id":"user-2","handle":"viewer"}
          }]
        }]}
        """
        let transport = SocialTransportStub(responses: [
            listPath: payload,
            likePath: #"{"liked":false,"likeCount":1}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let comments = try await adapter.rippleComments(postId: "ripple-1")
        XCTAssertEqual(comments.first?.replies.first?.content, "Reply")
        XCTAssertTrue(comments.first?.viewerLiked ?? false)

        let createTransport = SocialTransportStub(responses: [
            createPath: """
            {"comment":{"id":"new-1","userId":"user-1","content":"New",
            "parentId":null,"createdAt":"2026-07-26T10:02:00Z",
            "user":{"id":"user-1","handle":"ahmed"}}}
            """
        ])
        let createAdapter = LegacySocialAPIAdapter(transport: createTransport)
        let created = try await createAdapter.createRippleComment(
            postId: "ripple-1",
            content: "New",
            parentId: nil
        )
        XCTAssertEqual(created.content, "New")
        let createBodies = await createTransport.postBodies
        let body = try XCTUnwrap(createBodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "New")

        let like = try await adapter.toggleRippleCommentLike(commentId: "comment-1")
        XCTAssertFalse(like.liked)
        XCTAssertEqual(like.likeCount, 1)
    }

    func testMultiDestinationEchoUsesPostableVibesAndCanonicalRippleAttachment() async throws {
        let postablePath = "/api/fan-clubs/postable"
        let createPath = "/api/fan-clubs/cinema%20fans/posts"
        let transport = SocialTransportStub(responses: [
            postablePath: """
            {"vibes":[{"id":"v1","slug":"cinema fans","name":"Cinema Fans",
            "avatarUrl":null,"postingPolicy":"MEMBERS","isPersonal":false}]}
            """,
            createPath: """
            {"post":{"id":"echo-1","clubId":"v1","status":"PUBLISHED",
            "createdAt":"2026-07-26T10:00:00Z","author":{"id":"u1"}}}
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let destinations = try await adapter.postableVibes()
        XCTAssertEqual(destinations.first?.slug, "cinema fans")
        let post = try await adapter.createRipple(
            inVibe: "cinema fans",
            body: " My take ",
            attachments: [.ripple(id: "original-1")]
        )
        XCTAssertEqual(post.id, "echo-1")

        let postBodies = await transport.postBodies
        let body = try XCTUnwrap(postBodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, "My take")
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["type"] as? String, "WESTREEM_RIPPLE")
        XCTAssertEqual(attachments.first?["fanClubPostId"] as? String, "original-1")
    }

    func testPersonalFollowAndCommunityJoinUseDistinctFrozenEndpoints() async throws {
        let followPath = "/api/fan-clubs/my%20pulse/follow"
        let joinPath = "/api/fan-clubs/cinema/join"
        let transport = SocialTransportStub(responses: [
            followPath: #"{"following":true}"#,
            joinPath: #"{"pending":true}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let followed = try await adapter.followVibe(slug: "my pulse")
        let joined = try await adapter.joinVibe(slug: "cinema", message: "Let me in")
        XCTAssertTrue(followed.following)
        XCTAssertTrue(joined.pending)

        let postPaths = await transport.postPaths
        XCTAssertEqual(postPaths, [followPath, joinPath])
        let postBodies = await transport.postBodies
        let joinBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(postBodies.last)) as? [String: Any]
        )
        XCTAssertEqual(joinBody["message"] as? String, "Let me in")

        _ = try await adapter.unfollowVibe(slug: "my pulse")
        try await adapter.leaveVibe(slug: "cinema")
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(deletePaths, [followPath, joinPath])
    }

    func testComposerResolvesWestreemLinkAndPublishesPollWithoutChangingServerShape() async throws {
        let resolvePath = "/api/fan-clubs/resolve-attachment"
        let createPath = "/api/fan-clubs/cinema/posts"
        let transport = SocialTransportStub(responses: [
            resolvePath: """
            {"attachment":{"type":"WESTREEM_VIDEO","videoId":"video-1"},
            "preview":{"kind":"video","title":"Feature","subtitle":"WeStreem video"}}
            """,
            createPath: """
            {"post":{"id":"ripple-1","clubId":"v1","createdAt":"2026-07-26T10:00:00Z",
            "author":{"id":"u1"}}}
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let resolved = try await adapter.resolveAttachment(
            url: "https://www.westreem.com/watch/video-1"
        )
        XCTAssertEqual(resolved.attachment.createAttachment, .video(id: "video-1"))
        XCTAssertEqual(resolved.preview?.title, "Feature")

        _ = try await adapter.createRipple(
            inVibe: "cinema",
            body: nil,
            attachments: [.video(id: "video-1")],
            poll: RipplePollDraft(question: "Watch?", options: ["Yes", "Later"])
        )
        let postBodies = await transport.postBodies
        let createBody = try XCTUnwrap(postBodies.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: createBody) as? [String: Any]
        )
        let poll = try XCTUnwrap(object["poll"] as? [String: Any])
        XCTAssertEqual(poll["question"] as? String, "Watch?")
        XCTAssertEqual(poll["options"] as? [String], ["Yes", "Later"])
        XCTAssertEqual(poll["resultsVisibility"] as? String, "AFTER_VOTE")
    }
}

private actor SocialTransportStub: LegacySocialTransport {
    private let responses: [String: String]
    private(set) var paths: [String] = []
    private(set) var postPaths: [String] = []
    private(set) var postBodies: [Data] = []
    private(set) var deletePaths: [String] = []

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

    func socialDeleteData(path: String) async throws -> Data {
        deletePaths.append(path)
        guard let response = responses[path] else {
            throw StubError.missing(path)
        }
        return Data(response.utf8)
    }

    enum StubError: Error {
        case missing(String)
    }
}
