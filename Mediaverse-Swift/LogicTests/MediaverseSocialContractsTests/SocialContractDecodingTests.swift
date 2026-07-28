import XCTest
@testable import MediaverseSocialContracts

final class SocialContractDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testWaveTypePreservesUnknownServerValues() throws {
        let data = Data(
            """
            {"waves":[{"id":"w1","name":"Future","slug":"future","type":"FUTURE_WAVE",
            "visibility":"PUBLIC","postingPolicy":"MEMBERS","position":1,"isSystem":false,
            "isDefault":false,"commentsEnabled":true,"requiresPostApproval":false,
            "allowPolls":true,"allowPhotos":true,"allowLinks":true,"allowEchoes":true,
            "archivedAt":null,"capabilities":{"canView":true,"canPost":false,
            "canCreateEvent":false,"canManage":false,"canArchive":false}}]}
            """.utf8
        )
        let response = try decoder.decode(VibeWavesResponse.self, from: data)
        XCTAssertEqual(response.waves.first?.type, .unknown("FUTURE_WAVE"))
    }

    func testWaveDefaultsOmittedAdditiveFieldsToSafeValues() throws {
        let data = Data(
            """
            {"waves":[
              {"id":"w1","name":"Legacy General","slug":"general"},
              {"id":"w2","name":"Partial Events","slug":"events","type":"EVENTS",
               "_count":{"posts":3},"capabilities":{"canView":true}}
            ]}
            """.utf8
        )

        let response = try decoder.decode(VibeWavesResponse.self, from: data)
        let legacy = try XCTUnwrap(response.waves.first)
        let partial = try XCTUnwrap(response.waves.last)

        XCTAssertEqual(legacy.type, .custom)
        XCTAssertEqual(legacy.visibility, "MEMBERS")
        XCTAssertEqual(legacy.postingPolicy, "ADMINS")
        XCTAssertTrue(legacy.requiresPostApproval)
        XCTAssertFalse(legacy.commentsEnabled)
        XCTAssertFalse(legacy.allowPolls)
        XCTAssertFalse(legacy.capabilities.canView)
        XCTAssertFalse(legacy.capabilities.canManage)

        XCTAssertEqual(partial.type, .events)
        XCTAssertTrue(partial.capabilities.canView)
        XCTAssertFalse(partial.capabilities.canPost)
        XCTAssertEqual(partial._count?.posts, 3)
        XCTAssertEqual(partial._count?.events, 0)
    }

    func testStructuredRulesFailClosedForOmittedAdditiveFields() throws {
        let response = try decoder.decode(
            VibeRulesResponse.self,
            from: Data(
                """
                {"rules":[
                  {"id":"r1","title":"Be kind","description":"Respect everyone.","position":2,"enabled":true},
                  {"id":"r2"}
                ],"futurePolicy":"server-owned"}
                """.utf8
            )
        )

        XCTAssertFalse(response.rolloutPending)
        XCTAssertEqual(response.rules.count, 2)
        XCTAssertEqual(response.rules[0].title, "Be kind")
        XCTAssertTrue(response.rules[0].enabled)
        XCTAssertEqual(response.rules[1].title, "Rule")
        XCTAssertFalse(response.rules[1].enabled)

        let pending = try decoder.decode(
            VibeRulesResponse.self,
            from: Data(#"{"rolloutPending":true}"#.utf8)
        )
        XCTAssertTrue(pending.rolloutPending)
        XCTAssertTrue(pending.rules.isEmpty)
    }

    func testQuestionAndResourceRippleFieldsAreAdditive() throws {
        let response = try decoder.decode(
            RipplePageResponse.self,
            from: Data(
                """
                {"posts":[
                  {"id":"q1","clubId":"v1","createdAt":"2026-07-28T00:00:00Z",
                   "author":{"id":"u1"},"questionStatus":"ANSWERED","acceptedAnswerId":"c1",
                   "wave":{"id":"wq","slug":"questions","name":"Questions","type":"QUESTIONS"}},
                  {"id":"r1","clubId":"v1","createdAt":"2026-07-28T00:00:01Z",
                   "author":{"id":"u1"},"resourceCategory":"Guides","bookmarked":true,
                   "wave":{"id":"wr","slug":"resources","name":"Resources","type":"RESOURCES"}}
                ],"nextCursor":null,"resourceCategories":["Guides"],"futureSpecialization":true}
                """.utf8
            )
        )

        XCTAssertEqual(response.posts[0].wave?.type, .questions)
        XCTAssertEqual(response.posts[0].questionStatus, "ANSWERED")
        XCTAssertEqual(response.posts[0].acceptedAnswerId, "c1")
        XCTAssertEqual(response.posts[1].wave?.type, .resources)
        XCTAssertEqual(response.posts[1].resourceCategory, "Guides")
        XCTAssertTrue(response.posts[1].bookmarked)
        XCTAssertEqual(response.resourceCategories, ["Guides"])
    }

    func testSpecializedWaveUIPolicyGatesSensitiveControls() {
        XCTAssertTrue(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: true, canModerate: false))
        XCTAssertTrue(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: false, canModerate: true))
        XCTAssertFalse(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: false, canModerate: false))

        XCTAssertTrue(SpecializedWaveUIRules.canPublishResource(category: "Guides", hasAttachment: true))
        XCTAssertFalse(SpecializedWaveUIRules.canPublishResource(category: " ", hasAttachment: true))
        XCTAssertFalse(SpecializedWaveUIRules.canPublishResource(category: "Guides", hasAttachment: false))
    }

    func testWaveNotificationSettingsDefaultToInheritedDelivery() throws {
        let subscription = try decoder.decode(
            VibeWaveSubscription.self,
            from: Data(#"{"futureDeliveryPolicy":"digest"}"#.utf8)
        )

        XCTAssertEqual(subscription.notificationLevel, "INHERIT")
        XCTAssertTrue(subscription.pushEnabled)
        XCTAssertFalse(subscription.emailEnabled)
        XCTAssertEqual(
            subscription.effectiveNotificationLevel(inheriting: "MENTIONS"),
            "MENTIONS"
        )
    }

    func testWaveNotificationOverrideWinsOverInheritedVibeLevel() throws {
        let subscription = try decoder.decode(
            VibeWaveSubscription.self,
            from: Data(#"{"notificationLevel":"MUTED","pushEnabled":false,"emailEnabled":false}"#.utf8)
        )

        XCTAssertEqual(
            subscription.effectiveNotificationLevel(inheriting: "ALL"),
            "MUTED"
        )
    }

    func testVibeDetailDefaultsMissingCapabilitiesToDenied() throws {
        let data = Data(
            """
            {
              "club": {
                "id": "vibe-1",
                "slug": "cinema",
                "name": "Cinema",
                "topics": ["film"],
                "memberCount": 12,
                "followerCount": 4,
                "postCount": 8,
                "isPersonal": false
              },
              "capabilities": {
                "canView": true,
                "canViewContent": true,
                "canPost": true
              },
              "membership": null,
              "following": false
            }
            """.utf8
        )

        let response = try decoder.decode(VibeDetailResponse.self, from: data)

        XCTAssertTrue(response.capabilities.canViewContent)
        XCTAssertTrue(response.capabilities.canPost)
        XCTAssertFalse(response.capabilities.canManageClub)
        XCTAssertFalse(response.club.isPersonal)
    }

    func testRestrictedRipplePageDecodesWithoutPosts() throws {
        let data = Data(#"{"posts":[],"nextCursor":null,"restricted":true}"#.utf8)
        let response = try decoder.decode(RipplePageResponse.self, from: data)

        XCTAssertTrue(response.restricted)
        XCTAssertTrue(response.posts.isEmpty)
    }

    func testRippleDecodesKnownAndUnknownAttachmentsWithoutFailingPage() throws {
        let data = Data(
            """
            {
              "posts": [{
                "id": "ripple-1",
                "clubId": "vibe-1",
                "body": "A new ripple",
                "createdAt": "2026-07-26T10:00:00.000Z",
                "energyCount": 3,
                "energyTotal": 14,
                "energyTags": ["INSPIRED", "DEEP"],
                "author": {
                  "id": "user-1",
                  "name": "Ahmed",
                  "handle": "ahmed",
                  "image": null
                },
                "attachments": [{
                  "id": "attachment-1",
                  "type": "PHOTO",
                  "position": 0,
                  "imageUrl": "https://cdn.example.com/photo.jpg",
                  "likes": [{"id":"like-1"}]
                }, {
                  "id": "attachment-2",
                  "type": "FUTURE_TYPE",
                  "position": 1
                }]
              }],
              "nextCursor": "ripple-1"
            }
            """.utf8
        )

        let response = try decoder.decode(RipplePageResponse.self, from: data)

        XCTAssertEqual(response.posts.count, 1)
        XCTAssertEqual(response.posts[0].energyCount, 3)
        XCTAssertEqual(response.posts[0].attachments[0].type, .photo)
        XCTAssertTrue(response.posts[0].attachments[0].viewerLikedPhoto)
        XCTAssertEqual(response.posts[0].attachments[1].type, .unknown)
        XCTAssertEqual(response.nextCursor, "ripple-1")
    }

    func testRippleAcceptsDeployedEnergyTagCountObject() throws {
        let data = Data(
            """
            {
              "posts": [{
                "id": "ripple-legacy-energy",
                "createdAt": "2026-07-26T10:00:00.000Z",
                "energyTags": {"DEEP": 2, "INSPIRED": 5, "CHILL": 0},
                "author": {"id": "user-1"}
              }]
            }
            """.utf8
        )

        let response = try decoder.decode(RipplePageResponse.self, from: data)

        XCTAssertEqual(response.posts[0].energyTags, ["INSPIRED", "DEEP"])
    }

    func testEnergyAggregateAcceptsDeployedKeywordObjects() throws {
        let data = Data(
            """
            {
              "userRating":{"overall":4,"tags":["Inspired"],"review":null},
              "aggregate":{
                "avg":4.5,
                "count":2,
                "distribution":{"4":1,"5":1},
                "topTags":[{"tag":"Inspired","count":2},{"tag":"Deep","count":1}]
              }
            }
            """.utf8
        )

        let response = try decoder.decode(RippleEnergyResponse.self, from: data)

        XCTAssertEqual(response.aggregate.topTags, ["Inspired", "Deep"])
        XCTAssertEqual(response.aggregate.count, 2)
    }

    func testAtmosphereFeedKeepsRipplesAndRegularVideosOnly() throws {
        let data = Data(
            """
            [{
              "_kind": "fan_club_post",
              "id": "ripple-1",
              "createdAt": "2026-07-26T10:00:00.000Z",
              "author": {"id": "user-1"},
              "club": {"id":"vibe-1","slug":"cinema","name":"Cinema"},
              "poll": {
                "id":"poll-1",
                "question":"Ready?",
                "allowsMultiple":false,
                "maxSelections":1,
                "resultsVisibility":"AFTER_VOTE",
                "options":[{"id":"yes","label":"Yes"}]
              }
            }, {
              "_kind": "video",
              "id": "video-1",
              "title": "Video",
              "thumbnailUrl": null,
              "videoUrl": "/video.m3u8",
              "duration": 40,
              "views": 20,
              "type": "video",
              "contentRatings": [{"overall": 4, "tags": ["Inspired"]}],
              "_count": {"comments": 3, "fanClubAttachments": 2},
              "publishedAt": null,
              "createdAt": "2026-07-26T09:00:00.000Z"
            }, {
              "_kind": "video",
              "id": "short-1",
              "title": "Short",
              "views": 1,
              "type": "short",
              "createdAt": "2026-07-26T08:00:00.000Z"
            }, {
              "_kind": "episode",
              "id": "episode-1",
              "title": "Episode",
              "views": 1,
              "type": "episode",
              "createdAt": "2026-07-26T07:00:00.000Z"
            }]
            """.utf8
        )

        let feed = try decoder.decode(AtmosphereFeed.self, from: data)

        XCTAssertEqual(feed.items.count, 2)
        guard case .ripple(let ripple) = feed.items[0], case .video(let video) = feed.items[1] else {
            return XCTFail("Atmosphere must retain Ripple then regular video")
        }
        XCTAssertNil(ripple.clubId)
        XCTAssertEqual(ripple.club?.slug, "cinema")
        XCTAssertFalse(ripple.poll?.allowsVoteChanges ?? true)
        XCTAssertEqual(ripple.poll?.votes.count, 0)
        XCTAssertEqual(video.contentRatings?.first?.overall, 4)
        XCTAssertEqual(video.counts?.comments, 3)
        XCTAssertEqual(video.counts?.fanClubAttachments, 2)
    }

    func testPollDefaultsOptionalCountsAndPositions() throws {
        let data = Data(
            """
            {
              "posts": [{
                "id": "ripple-poll",
                "clubId": "vibe-1",
                "createdAt": "2026-07-26T10:00:00.000Z",
                "author": {"id": "user-1"},
                "poll": {
                  "id": "poll-1",
                  "question": "Pick one",
                  "allowsMultiple": false,
                  "maxSelections": 1,
                  "allowsVoteChanges": true,
                  "resultsVisibility": "AFTER_VOTE",
                  "options": [
                    {"id": "one", "label": "One"},
                    {"id": "two", "label": "Two", "position": 1, "voteCount": 4}
                  ],
                  "votes": [{"optionId": "two"}]
                }
              }],
              "nextCursor": null
            }
            """.utf8
        )

        let response = try decoder.decode(RipplePageResponse.self, from: data)
        let poll = try XCTUnwrap(response.posts.first?.poll)

        XCTAssertEqual(poll.options[0].voteCount, 0)
        XCTAssertEqual(poll.options[1].voteCount, 4)
        XCTAssertEqual(poll.votes.first?.optionId, "two")
    }

    func testRippleCommentDefaultsMissingReplyAndLikeCollections() throws {
        let data = Data(
            """
            {"comments":[{
              "id":"comment-1",
              "userId":"user-1",
              "content":"Hello @viewer",
              "createdAt":"2026-07-26T10:00:00Z",
              "user":{"id":"user-1","handle":"author"}
            }]}
            """.utf8
        )

        let response = try decoder.decode(RippleCommentsResponse.self, from: data)

        XCTAssertEqual(response.comments.first?.content, "Hello @viewer")
        XCTAssertEqual(response.comments.first?.likeCount, 0)
        XCTAssertEqual(response.comments.first?.replies.count, 0)
        XCTAssertFalse(response.comments.first?.viewerLiked ?? true)
    }

    func testSocialFeaturesDefaultOnForRelease() {
        let configuration = SocialFeatureConfiguration()

        XCTAssertNotEqual(configuration, .disabled)
        XCTAssertTrue(configuration.hasAnyEnabledFeature)
        XCTAssertTrue(configuration.atmosphereEnabled)
        XCTAssertTrue(configuration.rippleComposerEnabled)
        XCTAssertFalse(SocialFeatureConfiguration.disabled.hasAnyEnabledFeature)
    }

    func testRuntimeFeatureConfigurationSupportsExplicitKillSwitches() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "SocialContractDecodingTests"))
        suite.removePersistentDomain(forName: "SocialContractDecodingTests")
        suite.set(true, forKey: "social.atmosphere.enabled")
        suite.set(false, forKey: "social.ripple-engagement.enabled")

        let configuration = SocialFeatureConfiguration.runtime(userDefaults: suite)

        XCTAssertTrue(configuration.atmosphereEnabled)
        XCTAssertTrue(configuration.discoverEnabled)
        XCTAssertFalse(configuration.rippleEngagementEnabled)
        suite.removePersistentDomain(forName: "SocialContractDecodingTests")
    }
}
