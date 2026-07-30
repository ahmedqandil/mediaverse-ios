import XCTest
@testable import MediaverseSocialContracts

final class AtmoV2ContractsTests: XCTestCase {
    func testPersonalAtmoV2DefaultsOff() {
        let suite = "atmo-v2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SocialFeatureConfiguration.runtime(userDefaults: defaults).personalAtmoV2Enabled)
    }

    func testRepositoryRefusesTrafficWhileLocalGateIsOff() async {
        let transport = AtmoV2TransportSpy(response: Data())
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: false)
        )
        do {
            _ = try await repository.profile(userID: "user-1")
            XCTFail("Expected default-off repository to reject the request")
        } catch {
            XCTAssertEqual(error as? AtmoV2RepositoryError, .disabled)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testProfileUsesV2WestreemContract() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "user":{"id":"u1","name":"A","handle":"a","image":null,"bannerUrl":null,"bio":null},
          "profile":{"visibility":"PUBLIC","commentsEnabled":true,"followerCount":3,"postCount":2},
          "viewer":{"owner":false,"following":true}
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )
        let profile = try await repository.profile(userID: "u1")
        XCTAssertEqual(profile.authority, "WESTREEM")
        XCTAssertEqual(profile.version, 2)
        XCTAssertTrue(profile.viewer.following)
        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/api/v2/atmo/profiles/u1")
        XCTAssertEqual(request?.method, .get)
    }

    func testHandleResolverUsesCanonicalV2RouteAndPreservesWestreemAuthority() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,"resolvedBy":"handle",
          "user":{"id":"immutable-u1","name":"A","handle":"ahmed","image":null,"bannerUrl":null,"bio":null},
          "profile":{"visibility":"PUBLIC","commentsEnabled":true,"followerCount":0,"postCount":0},
          "viewer":{"owner":false,"following":false}
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        let profile = try await repository.profile(handle: " @AHMED ")

        XCTAssertEqual(profile.user.id, "immutable-u1")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/api/v2/atmo/profiles/by-handle/ahmed")
    }

    func testPhotoUploadTicketUsesDedicatedAtmoSignerContract() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "uploadUrl":"https://r2.example/signed",
          "objectKey":"atmo/u1/images/photo.jpg",
          "deliveryUrl":"https://cdn.example/atmo/u1/images/photo.jpg",
          "mediaType":"image","needsTranscode":false,"maxBytes":20971520
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        let ticket = try await repository.requestPhotoUpload(mimeType: "image/jpeg", bytes: 2048)

        XCTAssertEqual(ticket.objectKey, "atmo/u1/images/photo.jpg")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/api/v2/atmo/media/upload-url")
        XCTAssertEqual(request?.method, .post)
        let body = try XCTUnwrap(request?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(object["bytes"] as? Int, 2048)
    }

    func testInvalidAuthorityFailsClosed() async {
        let response = """
        {
          "authority":"MATRIX","version":2,
          "user":{"id":"u1","name":null,"handle":null,"image":null,"bannerUrl":null,"bio":null},
          "profile":{"visibility":"PUBLIC","commentsEnabled":true,"followerCount":0,"postCount":0},
          "viewer":{"owner":false,"following":false}
        }
        """.data(using: .utf8)!
        let repository = WestreemAtmoV2Repository(
            transport: AtmoV2TransportSpy(response: response),
            rollout: AtmoV2Rollout(localEnabled: true)
        )
        do {
            _ = try await repository.profile(userID: "u1")
            XCTFail("Expected authority mismatch")
        } catch {
            XCTAssertEqual(error as? AtmoV2RepositoryError, .invalidAuthority)
        }
    }

    func testIdentifiersCannotInjectPathOrQuerySeparators() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "user":{"id":"u/1","name":null,"handle":null,"image":null,"bannerUrl":null,"bio":null},
          "profile":{"visibility":"PUBLIC","commentsEnabled":true,"followerCount":0,"postCount":0},
          "viewer":{"owner":true,"following":false}
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        _ = try await repository.profile(userID: "u/1?admin=true")

        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/api/v2/atmo/profiles/u%2F1%3Fadmin%3Dtrue")
    }

    func testCreateCarriesIdempotencyAndTypedEcho() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,"created":true,
          "post":{
            "id":"p1","body":"quote","status":"PUBLISHED","isSpoiler":false,
            "commentsDisabled":false,"pinnedAt":null,"editedAt":null,
            "publishedAt":"2026-07-29T00:00:00.000Z","createdAt":"2026-07-29T00:00:00.000Z",
            "updatedAt":"2026-07-29T00:00:00.000Z",
            "author":{"id":"u1","name":"A","handle":"a","image":null,"verified":false},
            "counts":{"comments":0,"echoes":0,"energy":0,"shares":0},
            "energy":null,"attachments":[],"poll":null,
            "echo":{"id":"e1","sourceType":"ATMO_POST","sourceId":"p0","sourceUrl":null,"quote":"quote","createdAt":"2026-07-29T00:00:00.000Z"}
          }
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmoV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )
        _ = try await repository.create(
            AtmoV2PostDraft(
                clientRequestId: "request-1",
                body: "quote",
                echo: AtmoV2EchoDraft(
                    sourceType: "ATMO_POST", sourceId: "p0",
                    sourceUrl: nil, quote: "quote"
                )
            )
        )
        let request = await transport.lastRequest
        let json = try XCTUnwrap(request?.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertEqual(object["clientRequestId"] as? String, "request-1")
        XCTAssertEqual((object["echo"] as? [String: Any])?["sourceType"] as? String, "ATMO_POST")
        XCTAssertEqual(request?.method, .post)
    }

    func testAtmosphereFeedUsesWestreemV2CursorContract() async throws {
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "items":[
            {
              "id":"atmo:p1","kind":"ATMO_POST",
              "occurredAt":"2026-07-29T00:00:00.000Z","reason":"FOLLOWED_USER",
              "post":\(Self.atmoPostJSON)
            },
            {
              "id":"video:v1","kind":"VIDEO",
              "occurredAt":"2026-07-29T00:01:00.000Z","reason":"FOLLOWED_CHANNEL",
              "video":\(Self.videoJSON(type: "video", channel: true, show: false))
            }
          ],
          "nextCursor":"bmV4dC1wYWdl"
        }
        """.data(using: .utf8)!
        let transport = AtmoV2TransportSpy(response: response)
        let repository = WestreemAtmosphereV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        let page = try await repository.page(
            cursor: "Y3Vyc29yLTE",
            limit: 100
        )

        XCTAssertEqual(page.authority, "WESTREEM")
        XCTAssertEqual(page.version, 2)
        XCTAssertEqual(page.items.map(\.id), ["atmo:p1", "video:v1"])
        XCTAssertEqual(page.nextCursor, "bmV4dC1wYWdl")
        let request = await transport.lastRequest
        XCTAssertEqual(
            request?.path,
            "/api/v2/atmosphere/feed?limit=40&cursor=Y3Vyc29yLTE"
        )
        XCTAssertEqual(request?.method, .get)
    }

    func testAtmosphereFeedDropsUnsafeOrUnsupportedCandidates() async throws {
        let pendingPost = Self.atmoPostJSON.replacingOccurrences(
            of: "\"status\":\"PUBLISHED\"",
            with: "\"status\":\"PENDING\""
        )
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "items":[
            {
              "id":"video:s1","kind":"VIDEO",
              "occurredAt":"2026-07-29T00:00:00Z","reason":"FOLLOWED_CHANNEL",
              "video":\(Self.videoJSON(type: "short", channel: true, show: false, id: "s1"))
            },
            {
              "id":"video:v2","kind":"VIDEO",
              "occurredAt":"2026-07-29T00:01:00Z","reason":"FOLLOWED_SHOW",
              "video":\(Self.videoJSON(type: "video", channel: true, show: false, id: "v2"))
            },
            {
              "id":"atmo:p1","kind":"ATMO_POST",
              "occurredAt":"2026-07-29T00:02:00Z","reason":"FOLLOWED_USER",
              "post":\(pendingPost)
            },
            {
              "id":"future:x1","kind":"FUTURE_KIND",
              "occurredAt":"2026-07-29T00:03:00Z","reason":"RECOMMENDED"
            }
          ],
          "nextCursor":null
        }
        """.data(using: .utf8)!
        let repository = WestreemAtmosphereV2Repository(
            transport: AtmoV2TransportSpy(response: response),
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        let page = try await repository.page()

        XCTAssertTrue(page.items.isEmpty)
    }

    func testAtmosphereFeedAdmitsOnlyExplicitSafePublicHighlight() async throws {
        let safe = Self.highlightJSON(eventID: "$safe", visibility: "PUBLIC")
        let privateHighlight = Self.highlightJSON(
            eventID: "$private",
            visibility: "PRIVATE"
        )
        let encryptedHighlight = Self.highlightJSON(
            eventID: "$encrypted",
            visibility: "PUBLIC",
            encrypted: true
        )
        let response = """
        {
          "authority":"WESTREEM","version":2,
          "items":[
            {
              "id":"matrix:!room:vibes.westreem.com:$safe",
              "kind":"MATRIX_HIGHLIGHT",
              "occurredAt":"2026-07-29T00:00:00Z",
              "reason":"EXPLICIT_VIBE_HIGHLIGHT",
              "highlight":\(safe)
            },
            {
              "id":"matrix:!room:vibes.westreem.com:$private",
              "kind":"MATRIX_HIGHLIGHT",
              "occurredAt":"2026-07-29T00:00:00Z",
              "reason":"EXPLICIT_VIBE_HIGHLIGHT",
              "highlight":\(privateHighlight)
            },
            {
              "id":"matrix:!room:vibes.westreem.com:$encrypted",
              "kind":"MATRIX_HIGHLIGHT",
              "occurredAt":"2026-07-29T00:00:00Z",
              "reason":"EXPLICIT_VIBE_HIGHLIGHT",
              "highlight":\(encryptedHighlight)
            }
          ],
          "nextCursor":null
        }
        """.data(using: .utf8)!
        let repository = WestreemAtmosphereV2Repository(
            transport: AtmoV2TransportSpy(response: response),
            rollout: AtmoV2Rollout(localEnabled: true)
        )

        let page = try await repository.page()

        XCTAssertEqual(page.items.map(\.id), [
            "matrix:!room:vibes.westreem.com:$safe"
        ])
    }

    func testAtmosphereFeedFailsClosedForWrongAuthorityAndInvalidCursor() async {
        let wrongAuthority = """
        {"authority":"MATRIX","version":2,"items":[],"nextCursor":null}
        """.data(using: .utf8)!
        let repository = WestreemAtmosphereV2Repository(
            transport: AtmoV2TransportSpy(response: wrongAuthority),
            rollout: AtmoV2Rollout(localEnabled: true)
        )
        do {
            _ = try await repository.page()
            XCTFail("Expected authority mismatch")
        } catch {
            XCTAssertEqual(
                error as? AtmoV2RepositoryError,
                .invalidAuthority
            )
        }

        let transport = AtmoV2TransportSpy(response: wrongAuthority)
        let cursorRepository = WestreemAtmosphereV2Repository(
            transport: transport,
            rollout: AtmoV2Rollout(localEnabled: true)
        )
        do {
            _ = try await cursorRepository.page(cursor: "not/a/cursor")
            XCTFail("Expected invalid cursor rejection")
        } catch {
            XCTAssertEqual(
                error as? AtmoV2RepositoryError,
                .invalidPayload
            )
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    private static let atmoPostJSON = """
    {
      "id":"p1","body":"Public Atmo","status":"PUBLISHED",
      "isSpoiler":false,"commentsDisabled":false,
      "pinnedAt":null,"editedAt":null,
      "publishedAt":"2026-07-29T00:00:00Z",
      "createdAt":"2026-07-29T00:00:00Z",
      "updatedAt":"2026-07-29T00:00:00Z",
      "author":{
        "id":"u1","name":"A","handle":"a","image":null,"verified":false
      },
      "counts":{"comments":0,"echoes":0,"energy":0,"shares":0},
      "energy":null,"attachments":[],"poll":null,"echo":null
    }
    """

    private static func videoJSON(
        type: String,
        channel: Bool,
        show: Bool,
        id: String = "v1"
    ) -> String {
        """
        {
          "id":"\(id)","title":"Video","thumbnailUrl":null,
          "thumbnailFocus":null,"videoUrl":"https://cdn.example/video.m3u8",
          "duration":30,"views":4,"type":"\(type)","description":null,
          "publishedAt":"2026-07-29T00:00:00Z",
          "createdAt":"2026-07-29T00:00:00Z",
          "channel":\(channel ? """
            {"id":"c1","name":"Channel","handle":"channel","avatarUrl":null}
            """ : "null"),
          "show":\(show ? """
            {"id":"s1","title":"Show","coverUrl":null}
            """ : "null"),
          "contentRatings":null,
          "_count":{"comments":0,"fanClubAttachments":0}
        }
        """
    }

    private static func highlightJSON(
        eventID: String,
        visibility: String,
        encrypted: Bool = false
    ) -> String {
        """
        {
          "schemaVersion":1,"authority":"MATRIX","kind":"PUBLIC_HIGHLIGHT",
          "explicitHighlight":true,
          "roomId":"!room:vibes.westreem.com","eventId":"\(eventID)",
          "visibility":"\(visibility)","encrypted":\(encrypted),
          "redacted":false,"deleted":false,"moderated":false,
          "shareAllowed":true,"occurredAt":"2026-07-29T00:00:00Z",
          "presentation":{
            "body":"Public Vibe highlight","roomName":"News",
            "canonicalUrl":"/vibes/news/waves/announcements",
            "author":{
              "matrixUserId":"@u_1:vibes.westreem.com",
              "westreemUserId":"u1","name":"A","handle":"a","image":null
            }
          }
        }
        """
    }
}

private actor AtmoV2TransportSpy: AtmoV2Transport {
    struct Request: Sendable {
        let path: String
        let method: AtmoV2HTTPMethod
        let body: Data?
    }

    let response: Data
    private(set) var requests: [Request] = []
    var requestCount: Int { requests.count }
    var lastRequest: Request? { requests.last }

    init(response: Data) { self.response = response }

    func atmoV2Data(path: String, method: AtmoV2HTTPMethod, body: Data?) async throws -> Data {
        requests.append(Request(path: path, method: method, body: body))
        return response
    }
}
