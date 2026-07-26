import XCTest
@testable import MediaverseSocialContracts

final class SocialContractDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

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

    func testAtmosphereFeedKeepsRipplesAndRegularVideosOnly() throws {
        let data = Data(
            """
            [{
              "_kind": "fan_club_post",
              "id": "ripple-1",
              "clubId": "vibe-1",
              "createdAt": "2026-07-26T10:00:00.000Z",
              "author": {"id": "user-1"}
            }, {
              "_kind": "video",
              "id": "video-1",
              "title": "Video",
              "thumbnailUrl": null,
              "videoUrl": "/video.m3u8",
              "duration": 40,
              "views": 20,
              "type": "video",
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
        guard case .ripple = feed.items[0], case .video = feed.items[1] else {
            return XCTFail("Atmosphere must retain Ripple then regular video")
        }
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

    func testSocialFeaturesDefaultOffToPreserveExistingAppBehavior() {
        let configuration = SocialFeatureConfiguration()

        XCTAssertEqual(configuration, .disabled)
        XCTAssertFalse(configuration.hasAnyEnabledFeature)
        XCTAssertFalse(configuration.atmosphereEnabled)
        XCTAssertFalse(configuration.rippleComposerEnabled)
    }
}
