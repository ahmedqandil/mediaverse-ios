import XCTest
@testable import MediaverseSocialContracts

final class SocialContractDecodingTests: XCTestCase {
    func testCommunityVibePresentationAlwaysStartsInWaveDirectory() {
        XCTAssertEqual(
            VibeDestinationPresentation.resolve(
                isPersonal: false,
                selectedWaveSlug: nil,
                showsHomeConversation: false
            ),
            .waveDirectory
        )
    }

    func testSelectedWaveAlwaysUsesConversationPresentation() {
        XCTAssertEqual(
            VibeDestinationPresentation.resolve(
                isPersonal: false,
                selectedWaveSlug: "general",
                showsHomeConversation: false
            ),
            .waveConversation
        )
    }

    func testCommunityHomeRestoresOverviewPresentation() {
        XCTAssertEqual(
            VibeDestinationPresentation.resolve(
                isPersonal: false,
                selectedWaveSlug: nil,
                showsHomeConversation: true
            ),
            .communityOverview
        )
    }

    func testPersonalVibeKeepsFeedPresentation() {
        XCTAssertEqual(
            VibeDestinationPresentation.resolve(
                isPersonal: true,
                selectedWaveSlug: "ignored",
                showsHomeConversation: true
            ),
            .personalFeed
        )
    }

    private let decoder = JSONDecoder()

    func testMatrixSessionAndWaveBindingFailClosed() throws {
        let envelope = try decoder.decode(
            MatrixClientSessionEnvelope.self,
            from: Data(
                """
                {"session":{"accessToken":"ephemeral","deviceId":"IOS1","userId":"@u:matrix.test",
                "homeserverUrl":"https://matrix.test","expiresAt":"2099-07-29T12:00:00Z"}}
                """.utf8
            )
        )
        XCTAssertTrue(envelope.session.isUsable(at: Date(timeIntervalSince1970: 0)))

        let response = try decoder.decode(
            VibeWavesResponse.self,
            from: Data(
                """
                {"waves":[
                  {"id":"legacy","name":"Legacy","slug":"legacy"},
                  {"id":"ready","name":"Ready","slug":"ready",
                   "matrixBinding":{"roomId":"!wave:matrix.test","syncEnabled":true}}
                ]}
                """.utf8
            )
        )
        XCTAssertNil(response.waves[0].matrixBinding)
        XCTAssertTrue(response.waves[1].matrixBinding?.isUsable == true)

        let unavailable = try decoder.decode(
            MatrixSyncStatus.self,
            from: Data(#"{"available":true,"identityReady":true}"#.utf8)
        )
        XCTAssertFalse(unavailable.canStartClient)
    }

    func testMatrixSyncNormalizesTypingUnreadAndLatestEvent() throws {
        let response = try decoder.decode(
            MatrixSyncResponse.self,
            from: Data(
                """
                {
                  "next_batch":"s72595_4483",
                  "rooms":{"join":{"!wave:matrix.test":{
                    "unread_notifications":{"notification_count":4},
                    "timeline":{"events":[
                      {"type":"m.room.message","event_id":"$one","content":{"body":"one"}},
                      {"type":"m.room.message","event_id":"$two","content":{"body":"two"}}
                    ]},
                    "ephemeral":{"events":[
                      {"type":"m.typing","content":{"user_ids":["@a:test","@b:test"]}}
                    ]}
                  }}}
                }
                """.utf8
            )
        )
        let room = try XCTUnwrap(response.joinedRooms["!wave:matrix.test"])
        XCTAssertEqual(response.nextBatch, "s72595_4483")
        XCTAssertEqual(room.unreadCount, 4)
        XCTAssertEqual(room.latestEventId, "$two")
        XCTAssertEqual(room.typingUserIds, ["@a:test", "@b:test"])
    }

    func testPendingWaveRippleKeepsIdempotencyAcrossRetryState() throws {
        var pending = PendingWaveRipple(
            vibeSlug: "cinema",
            waveId: "wave-1",
            body: "Hello",
            idempotencyKey: "ios-stable-1"
        )
        pending.state = .retrying
        pending.attemptCount += 1
        let restored = try decoder.decode(
            PendingWaveRipple.self,
            from: JSONEncoder().encode(pending)
        )
        XCTAssertEqual(restored.idempotencyKey, "ios-stable-1")
        XCTAssertEqual(restored.state, .retrying)
        XCTAssertEqual(restored.attemptCount, 1)
    }

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

    func testWaveRippleDecodesLatestReplyPreviewWithoutChangingLegacyDefaults() throws {
        let response = try decoder.decode(
            RipplePageResponse.self,
            from: Data(
                """
                {"posts":[
                  {"id":"with-preview","createdAt":"2026-07-29T10:00:00Z","author":{"id":"u1"},
                   "commentCount":4,"commentPreview":[
                     {"id":"c1","userId":"u2","content":"Latest thought","createdAt":"2026-07-29T10:03:00Z",
                      "user":{"id":"u2","name":"Maya"}}
                   ]},
                  {"id":"legacy","createdAt":"2026-07-29T10:01:00Z","author":{"id":"u1"}}
                ]}
                """.utf8
            )
        )

        XCTAssertEqual(response.posts[0].commentPreview.first?.content, "Latest thought")
        XCTAssertEqual(response.posts[0].commentPreview.first?.user.name, "Maya")
        XCTAssertTrue(response.posts[1].commentPreview.isEmpty)
    }

    func testWaveRippleDecodesNormalizedConversationSummaryAndBoundsPresentationData() throws {
        let response = try decoder.decode(
            RipplePageResponse.self,
            from: Data(
                """
                {"posts":[{
                  "id":"conversation","createdAt":"2026-07-29T10:00:00Z","author":{"id":"u1"},
                  "commentCount":99,
                  "conversationSummary":{
                    "latestReplies":[
                      {"id":"r1","content":"One","parentId":null,"createdAt":"2026-07-29T10:01:00Z","user":{"id":"u2","name":"Maya"}},
                      {"id":"r2","content":"Two","parentId":"r1","createdAt":"2026-07-29T10:02:00Z","user":{"id":"u3","name":"Omar"}},
                      {"id":"r3","content":"Three","parentId":null,"createdAt":"2026-07-29T10:03:00Z","user":{"id":"u2","name":"Maya"}},
                      {"id":"r4","content":"Hidden from preview","parentId":null,"createdAt":"2026-07-29T10:04:00Z","user":{"id":"u4","name":"Noor"}}
                    ],
                    "participants":[
                      {"id":"u2","name":"Maya"},{"id":"u3","name":"Omar"},
                      {"id":"u2","name":"Maya"},{"id":"u4","name":"Noor"}
                    ],
                    "replyCount":12,"lastActivityAt":"2026-07-29T10:04:00Z",
                    "unreadCount":3,"firstUnreadReplyId":"r2","state":"LOCKED","locked":true,
                    "capabilities":{"canReply":false,"canOpenDiscussion":true}
                  }
                }]}
                """.utf8
            )
        )

        let summary = try XCTUnwrap(response.posts[0].conversationSummary)
        XCTAssertEqual(summary.latestReplies.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(summary.participants.map(\.id), ["u2", "u3", "u4"])
        XCTAssertEqual(summary.replyCount, 12)
        XCTAssertEqual(summary.unreadCount, 3)
        XCTAssertEqual(summary.firstUnreadReplyId, "r2")
        XCTAssertEqual(summary.state, "LOCKED")
        XCTAssertTrue(summary.locked)
        XCTAssertFalse(summary.capabilities.canReply)
        XCTAssertTrue(summary.capabilities.canOpenDiscussion)
    }

    func testCanonicalCommentPreviewDerivesLegacyUserIDFromEmbeddedIdentity() throws {
        let data = Data(
            """
            {
              "posts":[{
                "id":"r-production",
                "createdAt":"2026-07-29T01:07:23.053Z",
                "author":{"id":"author-1","name":"Author"},
                "commentPreview":[{
                  "id":"reply-1",
                  "content":"Production preview",
                  "parentId":null,
                  "createdAt":"2026-07-29T01:07:32.944Z",
                  "user":{"id":"user-1","name":"Reader"}
                }],
                "conversationSummary":{
                  "latestReplies":[],
                  "participants":[],
                  "replyCount":1,
                  "unreadCount":0,
                  "state":"OPEN",
                  "locked":false,
                  "capabilities":{"canReply":true,"canOpenDiscussion":true}
                }
              }]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(RipplePageResponse.self, from: data)
        let preview = try XCTUnwrap(response.posts.first?.commentPreview.first)
        XCTAssertEqual(preview.userId, "user-1")
        XCTAssertEqual(preview.user.id, "user-1")
        XCTAssertEqual(preview.likeCount, 0)
        XCTAssertTrue(preview.replies.isEmpty)
    }

    func testConversationSummaryDefaultsCapabilitiesClosedAndCountsNonnegative() throws {
        let response = try decoder.decode(
            RipplePageResponse.self,
            from: Data(
                """
                {"posts":[{
                  "id":"safe","createdAt":"2026-07-29T10:00:00Z","author":{"id":"u1"},
                  "conversationSummary":{"replyCount":-4,"unreadCount":-2,"state":"LOCKED"}
                }]}
                """.utf8
            )
        )

        let summary = try XCTUnwrap(response.posts[0].conversationSummary)
        XCTAssertEqual(summary.replyCount, 0)
        XCTAssertEqual(summary.unreadCount, 0)
        XCTAssertTrue(summary.locked)
        XCTAssertFalse(summary.capabilities.canReply)
        XCTAssertTrue(summary.capabilities.canOpenDiscussion)
    }

    func testSpecializedWaveUIPolicyGatesSensitiveControls() {
        XCTAssertTrue(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: true, canModerate: false))
        XCTAssertTrue(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: false, canModerate: true))
        XCTAssertFalse(SpecializedWaveUIRules.canManageQuestionAnswer(isAuthor: false, canModerate: false))

        XCTAssertTrue(SpecializedWaveUIRules.canPublishResource(category: "Guides", hasAttachment: true))
        XCTAssertFalse(SpecializedWaveUIRules.canPublishResource(category: " ", hasAttachment: true))
        XCTAssertFalse(SpecializedWaveUIRules.canPublishResource(category: "Guides", hasAttachment: false))
    }

    func testWaveManagementPolicyMirrorsServerSpecializationInvariants() {
        func settings(_ type: VibeWaveType) -> VibeWaveSettings {
            VibeWaveSettings(
                name: "Wave",
                slug: "wave",
                description: nil,
                type: type,
                visibility: "PUBLIC",
                postingPolicy: "EVERYONE",
                position: -5,
                commentsEnabled: false,
                requiresPostApproval: true,
                allowPolls: true,
                allowPhotos: true,
                allowLinks: false,
                allowEchoes: true
            )
        }

        let announcements = VibeWaveManagementPolicy.normalized(settings(.announcements))
        XCTAssertEqual(announcements.postingPolicy, "ADMINS")
        XCTAssertFalse(announcements.requiresPostApproval)
        XCTAssertTrue(announcements.allowPolls)
        XCTAssertEqual(announcements.position, 0)

        let staff = VibeWaveManagementPolicy.normalized(settings(.staff))
        XCTAssertEqual(staff.visibility, "STAFF")
        XCTAssertEqual(staff.postingPolicy, "MODERATORS")

        XCTAssertTrue(VibeWaveManagementPolicy.normalized(settings(.questions)).commentsEnabled)
        XCTAssertTrue(VibeWaveManagementPolicy.normalized(settings(.resources)).allowLinks)
    }

    func testWaveLifecyclePolicyProtectsSystemAndDefaultAndRestoresArchived() {
        XCTAssertTrue(VibeWaveManagementPolicy.canArchive(
            isSystem: false, isDefault: false, isArchived: false, serverAllowsArchive: true
        ))
        XCTAssertFalse(VibeWaveManagementPolicy.canArchive(
            isSystem: true, isDefault: false, isArchived: false, serverAllowsArchive: true
        ))
        XCTAssertFalse(VibeWaveManagementPolicy.canArchive(
            isSystem: false, isDefault: true, isArchived: false, serverAllowsArchive: true
        ))
        XCTAssertTrue(VibeWaveManagementPolicy.canRestore(
            isSystem: false, isDefault: false, isArchived: true, serverAllowsManagement: true
        ))
        XCTAssertFalse(VibeWaveManagementPolicy.canRestore(
            isSystem: false, isDefault: false, isArchived: true, serverAllowsManagement: false
        ))
    }

    func testWaveNotificationSettingsDefaultToInheritedDelivery() throws {
        let subscription = try decoder.decode(
            VibeWaveSubscription.self,
            from: Data(#"{"futureDeliveryPolicy":"digest"}"#.utf8)
        )

        XCTAssertEqual(subscription.notificationLevel, "INHERIT")
        XCTAssertNil(subscription.pushEnabled)
        XCTAssertNil(subscription.emailEnabled)
        XCTAssertTrue(subscription.effectivePushEnabled(inheriting: true))
        XCTAssertFalse(subscription.effectiveEmailEnabled(inheriting: false))
        XCTAssertEqual(
            subscription.effectiveNotificationLevel(inheriting: "MENTIONS"),
            "MENTIONS"
        )
    }

    func testWaveNotificationOverrideWinsOverInheritedVibeLevel() throws {
        let subscription = try decoder.decode(
            VibeWaveSubscription.self,
            from: Data(#"{"notificationLevel":"OFF","pushEnabled":false,"emailEnabled":true}"#.utf8)
        )

        XCTAssertEqual(
            subscription.effectiveNotificationLevel(inheriting: "ALL"),
            "OFF"
        )
        XCTAssertFalse(subscription.effectivePushEnabled(inheriting: true))
        XCTAssertTrue(subscription.effectiveEmailEnabled(inheriting: false))
    }

    func testWaveDeliveryOverridePreservesTriStateContract() {
        XCTAssertEqual(WaveDeliveryOverride(nil), .inherit)
        XCTAssertEqual(WaveDeliveryOverride(true), .enabled)
        XCTAssertEqual(WaveDeliveryOverride(false), .disabled)
        XCTAssertNil(WaveDeliveryOverride.inherit.apiValue)
        XCTAssertEqual(WaveDeliveryOverride.enabled.apiValue, true)
        XCTAssertEqual(WaveDeliveryOverride.disabled.apiValue, false)
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
        XCTAssertFalse(configuration.matrixRealtimeEnabled)
        XCTAssertFalse(configuration.voiceRipplesEnabled)
        XCTAssertFalse(configuration.videoRipplesEnabled)
        XCTAssertFalse(configuration.liveEventRoomsEnabled)
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
        XCTAssertTrue(configuration.matrixRealtimeEnabled)
        suite.removePersistentDomain(forName: "SocialContractDecodingTests")
    }

    func testMatrixRolloutRequiresBothLocalAndServerGates() throws {
        let server = try decoder.decode(
            SocialRealtimeCapabilities.self,
            from: Data(
                """
                {"transport":"MATRIX","schemaVersion":1,"voiceRipples":true,
                 "videoRipples":true,"presence":true}
                """.utf8
            )
        )

        XCTAssertTrue(server.usesMatrix)
        XCTAssertFalse(
            SocialRealtimeRollout.voiceRipplesEnabled(
                local: SocialFeatureConfiguration(),
                server: server
            )
        )

        let local = SocialFeatureConfiguration(
            matrixRealtimeEnabled: true,
            voiceRipplesEnabled: true,
            videoRipplesEnabled: false
        )
        XCTAssertTrue(SocialRealtimeRollout.voiceRipplesEnabled(local: local, server: server))
        XCTAssertFalse(SocialRealtimeRollout.videoRipplesEnabled(local: local, server: server))
    }

    func testRealtimeCapabilitiesFailClosedForLegacyWave() throws {
        let response = try decoder.decode(
            VibeWavesResponse.self,
            from: Data(
                """
                {"waves":[
                  {"id":"legacy","name":"Legacy","slug":"legacy"},
                  {"id":"matrix","name":"Live","slug":"live","realtimeCapabilities":{
                    "transport":"MATRIX","schemaVersion":2,"presence":true,
                    "typing":true,"readReceipts":true,"offlineSend":true,
                    "threadSubscriptions":true,"directMessages":true,
                    "stickers":true,"voiceRipples":true,"videoRipples":true,
                    "liveEventRooms":true,"watchParties":true,"voiceLounges":true
                  }}
                ]}
                """.utf8
            )
        )

        XCTAssertNil(response.waves[0].realtimeCapabilities)
        let capabilities = try XCTUnwrap(response.waves[1].realtimeCapabilities)
        XCTAssertTrue(capabilities.usesMatrix)
        XCTAssertTrue(capabilities.voiceRipples)
        XCTAssertTrue(capabilities.watchParties)

        let legacy = try decoder.decode(
            SocialRealtimeCapabilities.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(legacy.usesMatrix)
        XCTAssertFalse(legacy.presence)
        XCTAssertFalse(legacy.videoRipples)
    }

    func testVoiceAndVideoRippleAttachmentsDecodeProcessingSafely() throws {
        let response = try decoder.decode(
            RipplePageResponse.self,
            from: Data(
                """
                {"posts":[{"id":"r1","createdAt":"2026-07-29T10:00:00Z","author":{"id":"u1"},
                  "attachments":[
                    {"id":"a1","type":"VOICE","conversationalMedia":{
                      "id":"media-voice","kind":"VOICE","status":"READY",
                      "playbackUrl":"https://media.example/voice.m4a",
                      "durationMilliseconds":42000,"waveform":[-1,12,9999]
                    }},
                    {"id":"a2","type":"VIDEO_MESSAGE","conversationalMedia":{
                      "id":"media-video","kind":"VIDEO","status":"PROCESSING"
                    }}
                  ]
                }]}
                """.utf8
            )
        )

        XCTAssertEqual(response.posts[0].attachments[0].type, .voice)
        let voice = try XCTUnwrap(response.posts[0].attachments[0].conversationalMedia)
        XCTAssertTrue(voice.isPlayable)
        XCTAssertEqual(voice.waveform, [0, 12, 1024])
        XCTAssertEqual(response.posts[0].attachments[1].type, .videoMessage)
        let video = try XCTUnwrap(response.posts[0].attachments[1].conversationalMedia)
        XCTAssertFalse(video.isPlayable)
        XCTAssertEqual(video.durationMilliseconds, 0)
    }

    func testConversationalMediaCreateAttachmentsEncodeStableIDsOnly() throws {
        let voice = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RippleCreateAttachment.voice(mediaId: "m-voice"))
        ) as? [String: String]
        let video = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RippleCreateAttachment.videoMessage(mediaId: "m-video"))
        ) as? [String: String]

        XCTAssertEqual(voice?["type"], "VOICE_MESSAGE")
        XCTAssertEqual(voice?["mediaId"], "m-voice")
        XCTAssertEqual(video?["type"], "VIDEO_MESSAGE")
        XCTAssertEqual(video?["mediaId"], "m-video")
        XCTAssertNil(video?["imageUrl"])
    }

    func testInteractivePollAndLeaderboardDecodeWithoutLeakingHiddenResults() throws {
        let poll = try decoder.decode(
            RipplePoll.self,
            from: Data(
                """
                {"id":"p1","question":"Who wins?","mode":"PREDICTION","anonymous":true,
                 "startsAt":"2026-07-29T10:00:00Z","closesAt":"2026-07-29T11:00:00Z",
                 "revealAt":"2026-07-29T12:00:00Z","points":20,
                 "leaderboardEnabled":true,"leaderboardVisibility":"AFTER_REVEAL",
                 "options":[{"id":"a","label":"A"}],"votes":[]}
                """.utf8
            )
        )
        XCTAssertEqual(poll.mode, "PREDICTION")
        XCTAssertTrue(poll.anonymous)
        XCTAssertEqual(poll.points, 20)
        XCTAssertTrue(poll.leaderboardEnabled)

        let hidden = try decoder.decode(
            InteractivePollLeaderboardResponse.self,
            from: Data(
                """
                {"serverTime":"2026-07-29T11:00:00Z","mode":"TRIVIA","anonymous":false,
                 "reveal":false,"correctOptionId":null,
                 "options":[{"id":"a","label":"A","voteCount":null}],
                 "viewerVotes":[],"leaderboard":null}
                """.utf8
            )
        )
        XCTAssertFalse(hidden.reveal)
        XCTAssertNil(hidden.correctOptionId)
        XCTAssertNil(hidden.options[0].voteCount)
        XCTAssertNil(hidden.leaderboard)
    }

    func testCollectionCollaborationAndWaveSummaryContractsDecode() throws {
        let collaboration = try decoder.decode(
            CollectionContributionsResponse.self,
            from: Data(
                """
                {"capabilities":{"canSuggest":true,"canReview":false},"contributions":[{
                  "id":"c1","targetType":"VIDEO","targetId":"v1","status":"PENDING",
                  "comments":[],"votes":{"score":2,"count":2,"viewerValue":1}
                }]}
                """.utf8
            )
        )
        XCTAssertTrue(collaboration.capabilities.canSuggest)
        XCTAssertFalse(collaboration.capabilities.canReview)
        XCTAssertEqual(collaboration.contributions[0].votes.viewerValue, 1)

        let summaries = try decoder.decode(
            WaveConversationSummariesResponse.self,
            from: Data(
                """
                {"summaries":[{"id":"s1","content":"A verified summary.","citations":[{
                  "id":"r1","preview":"Source Ripple","author":"Member",
                  "href":"/vibes/demo/waves/general?ripple=r1"
                }]}]}
                """.utf8
            )
        )
        XCTAssertEqual(summaries.summaries[0].citations.count, 1)
    }

    func testWidgetRegistryResponseRequiresExactIOSApproval() throws {
        let approved = try decoder.decode(
            ApprovedWidgetResponse.self,
            from: Data(
                """
                {"allowed":true,"widget":{"key":"event-agenda","name":"Agenda","version":1,
                  "platform":"IOS","cspDirectives":{"connect-src":["self"]},"tokenScopes":[]}}
                """.utf8
            )
        )
        XCTAssertTrue(approved.canPresentNatively)
        let rejected = try decoder.decode(
            ApprovedWidgetResponse.self,
            from: Data(#"{"allowed":false,"reason":"not-approved"}"#.utf8)
        )
        XCTAssertFalse(rejected.canPresentNatively)
    }

    func testMatrixAuthorityContractKeepsProductStateInWestreem() throws {
        let contract = try decoder.decode(
            SocialAuthorityContract.self,
            from: Data(
                """
                {
                  "version":1,
                  "liveTransport":"MATRIX",
                  "canonicalProduct":"WESTREEM",
                  "matrixOwns":["REALTIME_DELIVERY","TYPING","READ_RECEIPTS","PRESENCE","ROOM_RELATIONS","RTC_SIGNALING"],
                  "westreemOwns":["VIBE_DIRECTORY","WAVE_CONFIGURATION","PUBLIC_RIPPLE_PRESENTATION","EVENTS","ENERGY","FEEDS","CURATION","MODERATION","AUDIT","ANALYTICS","PLAYBACK","ADS","AFFILIATIONS","NOTIFICATIONS","MEDIA_DELIVERY"]
                }
                """.utf8
            )
        )

        XCTAssertTrue(contract.permitsMatrixRealtime)
        XCTAssertEqual(contract.authority(for: .typing), .matrix)
        XCTAssertEqual(contract.authority(for: .energy), .westreem)
        XCTAssertEqual(contract.authority(for: .playback), .westreem)
        XCTAssertEqual(contract.authority(for: .ads), .westreem)
    }

    func testMatrixAuthorityContractFailsClosedWhenMatrixClaimsPlayback() throws {
        let contract = try decoder.decode(
            SocialAuthorityContract.self,
            from: Data(
                """
                {
                  "version":1,
                  "liveTransport":"MATRIX",
                  "canonicalProduct":"WESTREEM",
                  "matrixOwns":["REALTIME_DELIVERY","PLAYBACK"],
                  "westreemOwns":["PUBLIC_RIPPLE_PRESENTATION","EVENTS","ENERGY","FEEDS","CURATION","MODERATION","AUDIT","ANALYTICS","PLAYBACK","ADS","AFFILIATIONS","NOTIFICATIONS","MEDIA_DELIVERY"]
                }
                """.utf8
            )
        )

        XCTAssertFalse(contract.permitsMatrixRealtime)
    }
}
