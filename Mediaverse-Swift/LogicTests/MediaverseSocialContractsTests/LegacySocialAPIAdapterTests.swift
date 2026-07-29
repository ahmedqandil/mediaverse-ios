import XCTest
@testable import MediaverseSocialContracts

final class LegacySocialAPIAdapterTests: XCTestCase {
    func testConversationalMediaPreparationAndCompletionUseStableMediaIDContract() async throws {
        let preparePath = "/api/fan-clubs/cinema/media-messages/upload-url"
        let completePath = "/api/fan-clubs/cinema/media-messages/media-1/complete"
        let statusPath = "/api/fan-clubs/cinema/media-messages/media-1"
        let transport = SocialTransportStub(responses: [
            preparePath: """
            {"mediaId":"media-1","uploadUrl":"https://upload.example/media-1",
             "objectKey":"ripple-media/voice/media-1.m4a","method":"PUT",
             "headers":{"x-upload-token":"opaque"}}
            """,
            completePath: """
            {"media":{"id":"media-1","kind":"VOICE","status":"PROCESSING",
             "durationMilliseconds":42000}}
            """,
            statusPath: """
            {"media":{"id":"media-1","kind":"VOICE","status":"READY",
             "playbackUrl":"https://cdn.example/media-1.m4a","durationMilliseconds":42000}}
            """
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let prepared = try await adapter.prepareConversationalMediaUpload(
            toVibe: "cinema",
            kind: .voice,
            mimeType: "audio/mp4",
            size: 24_000,
            durationMilliseconds: 42_000
        )
        let media = try await adapter.completeConversationalMediaUpload(
            inVibe: "cinema",
            mediaId: prepared.mediaId,
            objectKey: prepared.objectKey
        )
        let ready = try await adapter.conversationalMediaStatus(
            inVibe: "cinema",
            mediaId: prepared.mediaId
        )

        XCTAssertEqual(prepared.mediaId, "media-1")
        XCTAssertEqual(prepared.method, "PUT")
        XCTAssertEqual(media.status, .processing)
        XCTAssertTrue(ready.isPlayable)
        let paths = await transport.postPaths
        XCTAssertEqual(paths, [preparePath, completePath])
        let reads = await transport.paths
        XCTAssertEqual(reads, [statusPath])
        let bodies = await transport.postBodies
        let prepare = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        )
        XCTAssertEqual(prepare["kind"] as? String, "VOICE")
        XCTAssertEqual(prepare["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(prepare["durationMilliseconds"] as? Int, 42_000)
        let completion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any]
        )
        XCTAssertEqual(completion["objectKey"] as? String, "ripple-media/voice/media-1.m4a")
    }

    func testWaveListAndScopedRippleFeedUseAdditiveContracts() async throws {
        let wavesPath = "/api/fan-clubs/cinema/waves"
        let feedPath = "/api/fan-clubs/cinema/posts?cursor=opaque%2B%2F%3D&wave=questions"
        let createPath = "/api/fan-clubs/cinema/posts"
        let transport = SocialTransportStub(responses: [
            wavesPath: """
            {"waves":[{"id":"w1","name":"Questions","slug":"questions","type":"QUESTIONS",
            "visibility":"PUBLIC","postingPolicy":"MEMBERS","position":30,"isSystem":false,
            "isDefault":false,"commentsEnabled":true,"requiresPostApproval":false,
            "allowPolls":true,"allowPhotos":true,"allowLinks":true,"allowEchoes":true,
            "archivedAt":null,"capabilities":{"canView":true,"canPost":true,
            "canCreateEvent":false,"canManage":false,"canArchive":false}}]}
            """,
            feedPath: #"{"posts":[],"nextCursor":null}"#,
            createPath: #"{"post":{"id":"r1","clubId":"v1","status":"PUBLISHED","createdAt":"2026-07-28T00:00:00Z","author":{"id":"u1"}}}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let waves = try await adapter.vibeWaves(slug: "cinema")
        _ = try await adapter.vibeRipples(slug: "cinema", cursor: "opaque+/=", wave: "questions")
        _ = try await adapter.createRipple(inVibe: "cinema", body: "Question", attachments: [], waveId: "w1")

        XCTAssertEqual(waves.first?.type, .questions)
        let paths = await transport.paths
        XCTAssertEqual(paths, [wavesPath, feedPath])
        let postBodies = await transport.postBodies
        let body = try XCTUnwrap(postBodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["waveId"] as? String, "w1")
    }

    func testWaveManagementUsesCanonicalMutationEndpointsAndPayload() async throws {
        let collection = "/api/fan-clubs/cinema/waves"
        let member = "/api/fan-clubs/cinema/waves/questions"
        let transport = SocialTransportStub(responses: [
            collection: #"{"wave":{"id":"w1"}}"#,
            "PATCH \(member)": #"{"wave":{"id":"w1"}}"#,
            member: #"{"archived":true}"#,
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)
        let settings = VibeWaveSettings(
            name: "Questions",
            slug: "questions",
            description: "Ask the community",
            type: .questions,
            visibility: "MEMBERS",
            postingPolicy: "MEMBERS",
            position: 30,
            commentsEnabled: true,
            requiresPostApproval: true,
            allowPolls: true,
            allowPhotos: false,
            allowLinks: true,
            allowEchoes: true
        )

        try await adapter.createVibeWave(vibeSlug: "cinema", settings: settings)
        try await adapter.updateVibeWave(vibeSlug: "cinema", waveSlug: "questions", settings: settings)
        try await adapter.archiveVibeWave(vibeSlug: "cinema", waveSlug: "questions")

        let postPaths = await transport.postPaths
        XCTAssertEqual(postPaths, [collection, "PATCH \(member)"])
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(deletePaths, [member])
        let bodies = await transport.postBodies
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "QUESTIONS")
        XCTAssertEqual(payload["visibility"] as? String, "MEMBERS")
        XCTAssertEqual(payload["requiresPostApproval"] as? Bool, true)
        XCTAssertEqual(payload["allowPhotos"] as? Bool, false)
    }

    func testWaveNotificationSettingsSendExplicitChannelInheritance() async throws {
        let path = "/api/fan-clubs/cinema/waves/questions/notification-settings"
        let transport = SocialTransportStub(responses: [
            "PATCH \(path)": #"{"settings":{"notificationLevel":"HIGHLIGHTS","pushEnabled":null,"emailEnabled":false}}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let settings = try await adapter.updateWaveNotificationSettings(
            vibeSlug: "cinema",
            waveSlug: "questions",
            notificationLevel: "HIGHLIGHTS",
            pushEnabled: nil,
            emailEnabled: false
        )

        XCTAssertEqual(settings.notificationLevel, "HIGHLIGHTS")
        XCTAssertNil(settings.pushEnabled)
        XCTAssertEqual(settings.emailEnabled, false)
        let writes = await transport.postPaths
        XCTAssertEqual(writes, ["PATCH \(path)"])
        let bodies = await transport.postBodies
        let body = try XCTUnwrap(bodies.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["notificationLevel"] as? String, "HIGHLIGHTS")
        XCTAssertTrue(payload["pushEnabled"] is NSNull)
        XCTAssertEqual(payload["emailEnabled"] as? Bool, false)
    }

    func testRulesQuestionsAndResourcesUseCanonicalSpecializationEndpoints() async throws {
        let rulesPath = "/api/fan-clubs/cinema/rules"
        let bookmarkPath = "/api/fan-club-posts/resource-1/bookmark"
        let answerPath = "/api/fan-club-posts/question-1/accepted-answer"
        let transport = SocialTransportStub(responses: [
            rulesPath: #"{"rules":[{"id":"rule-1","title":"Be kind","description":"Respect people","enabled":true}]}"#,
            bookmarkPath: #"{"bookmarked":true}"#,
            "PATCH \(answerPath)": #"{"acceptedAnswerId":"comment-1","questionStatus":"ANSWERED"}"#,
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let rules = try await adapter.vibeRules(slug: "cinema")
        let bookmarked = try await adapter.setResourceBookmarked(postId: "resource-1", bookmarked: true)
        let answer = try await adapter.acceptQuestionAnswer(postId: "question-1", commentId: "comment-1")

        XCTAssertEqual(rules.rules.first?.title, "Be kind")
        XCTAssertTrue(bookmarked)
        XCTAssertEqual(answer.questionStatus, "ANSWERED")
        let requestPaths = await transport.paths
        let mutationPaths = await transport.postPaths
        XCTAssertEqual(requestPaths, [rulesPath])
        XCTAssertEqual(mutationPaths, [bookmarkPath, "PATCH \(answerPath)"])
        let bodies = await transport.postBodies
        let answerBody = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies.last!) as? [String: Any])
        XCTAssertEqual(answerBody["commentId"] as? String, "comment-1")
    }

    func testResourceRippleCreationIncludesRequiredCategory() async throws {
        let path = "/api/fan-clubs/cinema/posts"
        let transport = SocialTransportStub(responses: [
            path: #"{"post":{"id":"r1","clubId":"v1","createdAt":"2026-07-28T00:00:00Z","author":{"id":"u1"}}}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        _ = try await adapter.createRipple(
            inVibe: "cinema",
            body: "Useful guide",
            attachments: [.link(externalURL: "https://example.com")],
            waveId: "resources-wave",
            resourceCategory: "Guides"
        )

        let bodies = await transport.postBodies
        let body = try XCTUnwrap(bodies.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["waveId"] as? String, "resources-wave")
        XCTAssertEqual(payload["resourceCategory"] as? String, "Guides")
    }

    func testResourceFiltersAndQuestionReopenUseCanonicalQueries() async throws {
        let feedPath = "/api/fan-clubs/cinema/posts?wave=resources&category=Guides&bookmarked=1"
        let reopenPath = "/api/fan-club-posts/question-1/accepted-answer"
        let transport = SocialTransportStub(responses: [
            feedPath: #"{"posts":[],"resourceCategories":["Guides","Tools"]}"#,
            reopenPath: #"{"acceptedAnswerId":null,"questionStatus":"OPEN"}"#,
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let page = try await adapter.vibeRipples(
            slug: "cinema",
            wave: "resources",
            resourceCategory: "Guides",
            bookmarkedOnly: true
        )
        let reopened = try await adapter.reopenQuestion(postId: "question-1")

        XCTAssertEqual(page.resourceCategories, ["Guides", "Tools"])
        XCTAssertEqual(reopened.questionStatus, "OPEN")
        let getPaths = await transport.paths
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(getPaths, [feedPath])
        XCTAssertEqual(deletePaths, [reopenPath])
    }

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

        try await adapter.removeEnergy(fromRipple: "ripple/one")
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(deletePaths, [path])
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

    func testPhotoUploadReusesVibeR2PreparationAndProxyContracts() async throws {
        let preparePath = "/api/fan-clubs/cinema/images/upload-url?purpose=post"
        let uploadPath = "/api/fan-clubs/cinema/images/upload-proxy?target=signed"
        let transport = SocialTransportStub(responses: [
            preparePath: """
            {"uploadUrl":"\(uploadPath)","objectKey":"stories/fan-clubs/u1/post/photo",
            "deliveryUrl":"https://cdn.example.com/photo.jpg"}
            """,
            uploadPath: #"{"uploaded":true,"mediaUrl":"https://cdn.example.com/photo.jpg"}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)
        let bytes = Data([0xFF, 0xD8, 0xFF])

        let photo = try await adapter.uploadRipplePhoto(
            toVibe: "cinema",
            data: bytes,
            mimeType: "image/jpeg"
        )

        XCTAssertEqual(photo.imageURL, "https://cdn.example.com/photo.jpg")
        XCTAssertEqual(photo.objectKey, "stories/fan-clubs/u1/post/photo")
        let uploadPaths = await transport.uploadPaths
        let uploadTypes = await transport.uploadContentTypes
        XCTAssertEqual(uploadPaths, [uploadPath])
        XCTAssertEqual(uploadTypes, ["image/jpeg"])
    }

    func testRipplePhotoEngagementUsesAttachmentSpecificFrozenEndpoints() async throws {
        let commentsPath = "/api/fan-club-attachments/photo%201/comments"
        let reactionPath = "/api/fan-club-attachments/photo%201/rating"
        let commentLikePath = "/api/fan-club-attachment-comments/comment%201/like"
        let transport = SocialTransportStub(responses: [
            commentsPath: """
            {"comments":[{"id":"comment 1","userId":"u1","content":"Nice",
            "parentId":null,"createdAt":"2026-07-26T10:00:00Z",
            "user":{"id":"u1","handle":"ahmed"}}],
            "comment":{"id":"comment 1","userId":"u1","content":"Nice",
            "parentId":null,"createdAt":"2026-07-26T10:00:00Z",
            "user":{"id":"u1","handle":"ahmed"}}}
            """,
            reactionPath: """
            {"userRating":{"overall":4,"tags":["REAL"],"review":null},
            "aggregate":{"avg":4.0,"count":1,
            "distribution":{"1":0,"2":0,"3":0,"4":1,"5":0},"topTags":["REAL"]},
            "overall":4,"tags":["REAL"],"review":null,"ok":true}
            """,
            commentLikePath: #"{"liked":true,"likeCount":2}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let comments = try await adapter.ripplePhotoComments(attachmentId: "photo 1")
        XCTAssertEqual(comments.first?.content, "Nice")
        let created = try await adapter.createRipplePhotoComment(
            attachmentId: "photo 1",
            content: "Nice",
            parentId: nil
        )
        XCTAssertEqual(created.id, "comment 1")

        let energy = try await adapter.ripplePhotoEnergy(attachmentId: "photo 1")
        XCTAssertEqual(energy.aggregate.avg, 4)
        let saved = try await adapter.addEnergy(
            toPhoto: "photo 1",
            overall: 4,
            tags: ["REAL"]
        )
        XCTAssertEqual(saved.tags, ["REAL"])
        let commentLike = try await adapter.toggleRipplePhotoCommentLike(commentId: "comment 1")
        XCTAssertEqual(commentLike.likeCount, 2)

        let postPaths = await transport.postPaths
        XCTAssertEqual(postPaths, [commentsPath, reactionPath, commentLikePath])
    }

    func testAffiliationRequesterWorkflowUsesExactFrozenContracts() async throws {
        let listPath = "/api/fan-clubs/cinema/affiliations"
        let searchPath = "/api/fan-clubs/cinema/affiliation-targets?type=SHOW&q=Star%20Wars"
        let cancelPath = "/api/fan-clubs/cinema/affiliations/aff%201"
        let affiliation = """
        {"id":"aff 1","entityType":"SHOW","relationshipType":"AFFILIATED_COMMUNITY",
        "status":"PENDING","requestMessage":"Official community","reviewNote":null,
        "isPrimary":true,"show":{"id":"show-1","title":"Star Wars","coverUrl":null}}
        """
        let transport = SocialTransportStub(responses: [
            listPath: "{\"affiliations\":[\(affiliation)]}",
            searchPath: """
            {"results":[{"id":"show-1","type":"SHOW","name":"Star Wars",
            "handle":null,"imageUrl":null}]}
            """,
            cancelPath: #"{"ok":true}"#
        ])
        let adapter = LegacySocialAPIAdapter(transport: transport)

        let rows = try await adapter.vibeAffiliations(slug: "cinema")
        XCTAssertEqual(rows.first?.status, .pending)
        let targets = try await adapter.affiliationTargets(
            slug: "cinema",
            type: .show,
            query: " Star Wars "
        )
        XCTAssertEqual(targets.first?.name, "Star Wars")

        let requestTransport = SocialTransportStub(responses: [
            listPath: "{\"affiliation\":\(affiliation)}"
        ])
        let requestAdapter = LegacySocialAPIAdapter(transport: requestTransport)
        let created = try await requestAdapter.requestAffiliation(
            slug: "cinema",
            entityType: .show,
            entityId: "show-1",
            message: " Official community ",
            isPrimary: true
        )
        XCTAssertEqual(created.entity?.displayName, "Star Wars")
        let requestBodies = await requestTransport.postBodies
        let body = try XCTUnwrap(requestBodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["entityType"] as? String, "SHOW")
        XCTAssertEqual(object["entityId"] as? String, "show-1")
        XCTAssertEqual(object["requestMessage"] as? String, "Official community")
        XCTAssertEqual(object["isPrimary"] as? Bool, true)

        try await adapter.cancelAffiliation(slug: "cinema", affiliationId: "aff 1")
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(deletePaths, [cancelPath])
    }

    func testAffiliationReviewUsesExactFrozenBackstageContract() async throws {
        let queueJSON = """
        {"affiliations":[{"id":"aff-1","entityType":"CHANNEL","relationshipType":"AFFILIATED_COMMUNITY","status":"PENDING","requestMessage":"Please connect us","reviewNote":null,"isPrimary":false,"club":{"id":"v-1","slug":"cinema","name":"Cinema","ownerId":"u-1"},"show":null,"channel":{"id":"c-1","name":"Cinema Channel","handle":"cinema"},"requestedBy":{"id":"u-1","name":"Ava","handle":"ava","image":null}}],"counts":{"total":1,"pending":1,"approved":0}}
        """
        let decisionJSON = """
        {"ok":true,"status":"APPROVED","relationshipType":"OFFICIAL"}
        """
        let transport = SocialTransportStub(responses: [
            "/api/backstage/affiliations?status=PENDING": queueJSON,
            "PATCH /api/backstage/affiliations": decisionJSON
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let queue = try await api.reviewableAffiliations(status: .pending)
        XCTAssertEqual(queue.affiliations.first?.club?.slug, "cinema")
        XCTAssertEqual(queue.counts.pending, 1)

        let decision = try await api.reviewAffiliation(
            id: "aff-1",
            action: .approve,
            note: "Verified",
            relationship: .official
        )
        XCTAssertTrue(decision.ok)
        XCTAssertEqual(decision.status, .approved)

        let paths = await transport.paths
        XCTAssertEqual(paths, ["/api/backstage/affiliations?status=PENDING"])
        let postPaths = await transport.postPaths
        XCTAssertEqual(postPaths, ["PATCH /api/backstage/affiliations"])
        let postedBodies = await transport.postBodies
        let body = try XCTUnwrap(postedBodies.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["affiliationId"] as? String, "aff-1")
        XCTAssertEqual(payload["action"] as? String, "approve")
        XCTAssertEqual(payload["note"] as? String, "Verified")
        XCTAssertEqual(payload["relationshipType"] as? String, "OFFICIAL")
    }

    func testRippleOwnerAndReportActionsUseFrozenContracts() async throws {
        let editedJSON = """
        {"post":{"id":"p-1","body":"Updated Ripple","isSpoiler":true,"commentsDisabled":false}}
        """
        let reportJSON = """
        {"report":{"id":"report-1","status":"OPEN"}}
        """
        let transport = SocialTransportStub(responses: [
            "PATCH /api/fan-club-posts/p-1": editedJSON,
            "/api/fan-club-posts/p-1": #"{"ok":true}"#,
            "/api/fan-clubs/cinema/reports": reportJSON
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let edited = try await api.editRipple(
            postId: "p-1",
            body: "Updated Ripple",
            isSpoiler: true,
            commentsDisabled: false
        )
        XCTAssertEqual(edited.body, "Updated Ripple")
        try await api.deleteRipple(postId: "p-1")
        let receipt = try await api.reportRipple(
            postId: "p-1",
            vibeSlug: "cinema",
            reason: "Spam",
            details: "Repeated promotional content"
        )
        XCTAssertEqual(receipt.status, "OPEN")

        let postPaths = await transport.postPaths
        XCTAssertEqual(postPaths, [
            "PATCH /api/fan-club-posts/p-1",
            "/api/fan-clubs/cinema/reports"
        ])
        let deletePaths = await transport.deletePaths
        XCTAssertEqual(deletePaths, ["/api/fan-club-posts/p-1"])
        let bodies = await transport.postBodies
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        XCTAssertEqual(report["targetType"] as? String, "POST")
        XCTAssertEqual(report["postId"] as? String, "p-1")
        XCTAssertEqual(report["reason"] as? String, "Spam")
    }

    func testVibeModerationUsesExactFrozenContracts() async throws {
        let posts = """
        {"posts":[{"id":"p-1","body":"Review me","status":"PENDING_REVIEW","hiddenReason":null,"author":{"id":"u-1","name":"Ava","handle":"ava","image":null}}]}
        """
        let reports = """
        {"reports":[{"id":"r-1","targetType":"POST","reason":"Spam","details":null,"status":"OPEN","severity":"NORMAL","post":{"id":"p-1","body":"Review me","content":null},"comment":null,"reportedUser":null}]}
        """
        let joins = """
        {"requests":[{"id":"j-1","message":"Let me in","createdAt":"2026-07-26T00:00:00.000Z","user":{"id":"u-2","name":"Noor","handle":"noor","image":null}}]}
        """
        let transport = SocialTransportStub(responses: [
            "/api/fan-clubs/cinema/moderation": posts,
            "/api/fan-clubs/cinema/moderation?view=reports": reports,
            "/api/fan-clubs/cinema/join-requests": joins,
            "/api/fan-club-posts/p-1/moderate": #"{"post":{"id":"p-1"}}"#,
            "PATCH /api/fan-clubs/cinema/reports/r-1": #"{"ok":true}"#,
            "PATCH /api/fan-clubs/cinema/join-requests/j-1": #"{"ok":true}"#
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let moderationRipples = try await api.moderationRipples(vibeSlug: "cinema")
        let moderationReports = try await api.moderationReports(vibeSlug: "cinema")
        let joinRequests = try await api.joinRequests(vibeSlug: "cinema")
        XCTAssertEqual(moderationRipples.count, 1)
        XCTAssertEqual(moderationReports.count, 1)
        XCTAssertEqual(joinRequests.count, 1)
        try await api.moderateRipple(postId: "p-1", action: "hide", reason: "Off topic")
        try await api.resolveReport(
            vibeSlug: "cinema",
            reportId: "r-1",
            status: "RESOLVED_ACTIONED",
            note: "Ripple hidden"
        )
        try await api.decideJoinRequest(
            vibeSlug: "cinema",
            requestId: "j-1",
            approve: true,
            note: "Welcome"
        )

        let readPaths = await transport.paths
        XCTAssertEqual(readPaths, [
            "/api/fan-clubs/cinema/moderation",
            "/api/fan-clubs/cinema/moderation?view=reports",
            "/api/fan-clubs/cinema/join-requests"
        ])
        let writePaths = await transport.postPaths
        XCTAssertEqual(writePaths, [
            "/api/fan-club-posts/p-1/moderate",
            "PATCH /api/fan-clubs/cinema/reports/r-1",
            "PATCH /api/fan-clubs/cinema/join-requests/j-1"
        ])
    }

    func testRippleAndPhotoCommentManagementUsesTargetSpecificContracts() async throws {
        let rippleComment = """
        {"comment":{"id":"c-1","userId":"u-1","content":"Updated","contentHtml":null,"parentId":null,"likeCount":0,"createdAt":"2026-07-26T00:00:00.000Z","editedAt":"2026-07-26T00:01:00.000Z","user":{"id":"u-1","name":"Ava","handle":"ava","image":null},"replies":[],"likes":[]}}
        """
        let photoComment = rippleComment.replacingOccurrences(of: "c-1", with: "pc-1")
        let transport = SocialTransportStub(responses: [
            "PATCH /api/fan-club-comments/c-1": rippleComment,
            "/api/fan-club-comments/c-1": #"{"ok":true}"#,
            "PATCH /api/fan-club-attachment-comments/pc-1": photoComment,
            "/api/fan-club-attachment-comments/pc-1": #"{"ok":true}"#
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        _ = try await api.editRippleComment(commentId: "c-1", content: "Updated")
        try await api.deleteRippleComment(commentId: "c-1")
        _ = try await api.editRipplePhotoComment(commentId: "pc-1", content: "Updated")
        try await api.deleteRipplePhotoComment(commentId: "pc-1")

        let writes = await transport.postPaths
        XCTAssertEqual(writes, [
            "PATCH /api/fan-club-comments/c-1",
            "PATCH /api/fan-club-attachment-comments/pc-1"
        ])
        let deletes = await transport.deletePaths
        XCTAssertEqual(deletes, [
            "/api/fan-club-comments/c-1",
            "/api/fan-club-attachment-comments/pc-1"
        ])
    }

    func testMemberModerationUsesFrozenCapabilityBackedContract() async throws {
        let members = """
        {"members":[{"id":"m-1","role":"MEMBER","joinedAt":"2026-07-01T00:00:00.000Z","user":{"id":"u-1","name":"Ava","handle":"ava","image":null}}],"nextCursor":null}
        """
        let updated = """
        {"member":{"id":"m-1","role":"MODERATOR","status":"ACTIVE"}}
        """
        let transport = SocialTransportStub(responses: [
            "/api/fan-clubs/cinema/members?q=%40ava": members,
            "PATCH /api/fan-clubs/cinema/members/u-1": updated
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let page = try await api.vibeMembers(vibeSlug: "cinema", query: "@ava")
        XCTAssertEqual(page.members.first?.user.handle, "ava")
        let member = try await api.updateVibeMember(
            vibeSlug: "cinema",
            userId: "u-1",
            role: "MODERATOR"
        )
        XCTAssertEqual(member.role, "MODERATOR")

        let reads = await transport.paths
        XCTAssertEqual(reads, ["/api/fan-clubs/cinema/members?q=%40ava"])
        let writes = await transport.postPaths
        XCTAssertEqual(writes, ["PATCH /api/fan-clubs/cinema/members/u-1"])
    }

    func testVibeInvitationsUseExactFrozenManagementAndAcceptanceContracts() async throws {
        let invite = """
        {"id":"invite-1","invitedEmail":null,"role":"MEMBER","maxUses":5,"useCount":0,
        "expiresAt":"2026-08-02T00:00:00.000Z","revokedAt":null,"acceptedAt":null,
        "createdAt":"2026-07-26T00:00:00.000Z","invitedUser":null,
        "invitedBy":{"id":"owner-1","name":"Owner","handle":"owner","image":null}}
        """
        let listPath = "/api/fan-clubs/cinema/invites"
        let revokePath = "/api/fan-clubs/cinema/invites/invite-1"
        let acceptPath = "/api/fan-club-invites/opaque%2Ftoken/accept"
        let transport = SocialTransportStub(responses: [
            listPath: #"{"invites":[\#(invite)]}"#,
            revokePath: #"{"ok":true}"#,
            acceptPath: #"{"membership":{"role":"MEMBER","status":"ACTIVE","muted":false},"slug":"cinema"}"#
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let rows = try await api.vibeInvites(slug: "cinema")
        XCTAssertEqual(rows.first?.id, "invite-1")
        try await api.revokeVibeInvite(slug: "cinema", inviteID: "invite-1")
        let accepted = try await api.acceptVibeInvite(token: "opaque/token")
        XCTAssertEqual(accepted.slug, "cinema")

        let readPaths = await transport.paths
        let deletePaths = await transport.deletePaths
        let postPaths = await transport.postPaths
        XCTAssertEqual(readPaths, [listPath])
        XCTAssertEqual(deletePaths, [revokePath])
        XCTAssertEqual(postPaths, [acceptPath])

        let createTransport = SocialTransportStub(responses: [
            listPath: #"{"invite":\#(invite),"token":"new-token"}"#
        ])
        let createAPI = LegacySocialAPIAdapter(transport: createTransport)
        _ = try await createAPI.createVibeInvite(
            slug: "cinema",
            invitedEmail: " member@example.com ",
            role: .moderator,
            expiresInDays: 99,
            maxUses: 300
        )
        let createBodies = await createTransport.postBodies
        let body = try XCTUnwrap(createBodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["invitedEmail"] as? String, "member@example.com")
        XCTAssertEqual(object["role"] as? String, "MODERATOR")
        XCTAssertEqual(object["expiresInDays"] as? Int, 30)
        XCTAssertEqual(object["maxUses"] as? Int, 100)
    }

    func testVibeCreationSettingsAndBrandingUseFrozenContracts() async throws {
        let club = """
        {"id":"v-1","slug":"film-fans","name":"Film Fans","description":"Talk cinema",
        "visibility":"INVITE_ONLY","joinPolicy":"REQUEST_APPROVAL","postingPolicy":"MEMBERS_WITH_REVIEW",
        "topics":["cinema"],"commentsEnabled":true,"membersCanInvite":true,
        "avatarUrl":"https://cdn.example/avatar.jpg","bannerUrl":null}
        """
        let createPath = "/api/fan-clubs"
        let updatePath = "/api/fan-clubs/film-fans"
        let preparePath = "/api/fan-clubs/film-fans/images/upload-url?purpose=profile"
        let uploadPath = "/api/fan-clubs/film-fans/images/upload-proxy?purpose=profile&target=signed"
        let transport = SocialTransportStub(responses: [
            createPath: #"{"club":\#(club)}"#,
            "PATCH \(updatePath)": #"{"club":\#(club)}"#,
            preparePath: """
            {"uploadUrl":"\(uploadPath)","objectKey":"stories/fan-clubs/u/profile/a.jpg",
            "deliveryUrl":"https://cdn.example/avatar.jpg","storage":"r2-proxy"}
            """,
            uploadPath: #"{"uploaded":true,"mediaUrl":"https://cdn.example/avatar.jpg"}"#
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let created = try await api.createVibe(
            name: " Film Fans ",
            slug: "film-fans",
            description: " Talk cinema ",
            visibility: .inviteOnly,
            joinPolicy: .requestApproval,
            topics: [" Cinema ", "cinema", "Movies"],
            language: " en ",
            country: "us"
        )
        XCTAssertEqual(created.slug, "film-fans")
        let createBodies = await transport.postBodies
        let createObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(createBodies.first)) as? [String: Any]
        )
        XCTAssertEqual(createObject["name"] as? String, "Film Fans")
        XCTAssertEqual(createObject["description"] as? String, "Talk cinema")
        XCTAssertEqual(createObject["visibility"] as? String, "INVITE_ONLY")
        XCTAssertEqual(createObject["joinPolicy"] as? String, "REQUEST_APPROVAL")
        XCTAssertEqual(createObject["topics"] as? [String], ["cinema", "movies"])
        XCTAssertEqual(createObject["country"] as? String, "US")

        _ = try await api.updateVibe(
            slug: "film-fans",
            settings: VibeSettingsUpdate(
                name: "Film Fans",
                description: "Talk cinema",
                visibility: .inviteOnly,
                joinPolicy: .requestApproval,
                postingPolicy: .membersWithReview,
                commentsEnabled: true,
                followersOnly: false,
                membersCanInvite: true,
                moderatorsCanInvite: false,
                moderatorsCanBan: false,
                topics: ["cinema"],
                language: "en",
                country: "US",
                avatarURL: "https://cdn.example/avatar.jpg",
                avatarFocus: "50% 50% 1.00",
                bannerURL: nil,
                bannerFocus: nil
            )
        )
        let uploaded = try await api.uploadVibeProfileImage(
            toVibe: "film-fans",
            data: Data([1, 2, 3]),
            mimeType: "image/jpeg"
        )
        XCTAssertEqual(uploaded.imageURL, "https://cdn.example/avatar.jpg")

        let writePaths = await transport.postPaths
        let uploadPaths = await transport.uploadPaths
        XCTAssertEqual(writePaths, [createPath, "PATCH \(updatePath)", preparePath])
        XCTAssertEqual(uploadPaths, [uploadPath])
    }

    func testProfilePinUsesFrozenRipplePatchContract() async throws {
        let path = "/api/fan-club-posts/ripple-1"
        let transport = SocialTransportStub(responses: [
            "PATCH \(path)": #"{"post":{"id":"ripple-1","pinnedAt":"2026-07-26T18:00:00.000Z"}}"#
        ])
        let api = LegacySocialAPIAdapter(transport: transport)

        let result = try await api.setRipplePinned(postId: "ripple-1", pinned: true)

        XCTAssertEqual(result.id, "ripple-1")
        XCTAssertNotNil(result.pinnedAt)
        let paths = await transport.postPaths
        XCTAssertEqual(paths, ["PATCH \(path)"])
        let bodies = await transport.postBodies
        let body = try XCTUnwrap(bodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["pinned"] as? Bool, true)
    }
}

private actor SocialTransportStub: LegacySocialTransport {
    private let responses: [String: String]
    private(set) var paths: [String] = []
    private(set) var postPaths: [String] = []
    private(set) var postBodies: [Data] = []
    private(set) var deletePaths: [String] = []
    private(set) var uploadPaths: [String] = []
    private(set) var uploadContentTypes: [String] = []

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

    func socialPatchData(path: String, body: Data) async throws -> Data {
        postPaths.append("PATCH \(path)")
        postBodies.append(body)
        guard let response = responses["PATCH \(path)"] ?? responses[path] else {
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

    func socialUploadData(path: String, body: Data, contentType: String) async throws -> Data {
        uploadPaths.append(path)
        uploadContentTypes.append(contentType)
        guard !body.isEmpty, let response = responses[path] else {
            throw StubError.missing(path)
        }
        return Data(response.utf8)
    }

    enum StubError: Error {
        case missing(String)
    }
}
