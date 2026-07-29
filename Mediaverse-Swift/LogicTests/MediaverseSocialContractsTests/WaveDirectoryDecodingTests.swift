import Foundation
import XCTest
@testable import MediaverseSocialContracts

final class WaveDirectoryDecodingTests: XCTestCase {
    func testDecodesExactNestedProductionDirectorySummary() throws {
        let response = try JSONDecoder().decode(
            VibeWavesResponse.self,
            from: Data(
                """
                {
                  "waves":[{
                    "id":"wave-1",
                    "name":"General",
                    "slug":"general",
                    "description":"Open conversation",
                    "type":"GENERAL",
                    "visibility":"PUBLIC",
                    "_count":{"posts":12,"events":0},
                    "directorySummary":{
                      "latestRippleId":"ripple-1",
                      "preview":"A visible conversation preview",
                      "participant":{
                        "id":"user-1",
                        "name":"Maya",
                        "handle":"maya",
                        "image":null
                      },
                      "lastActivityAt":"2026-07-29T05:10:00.000Z",
                      "unreadCount":7,
                      "rippleCount":12
                    },
                    "capabilities":{"canView":true,"canPost":true}
                  }]
                }
                """.utf8
            )
        )

        let wave = try XCTUnwrap(response.waves.first)
        XCTAssertEqual(wave.unreadCount, 7)
        XCTAssertEqual(wave.lastActivityAt, "2026-07-29T05:10:00.000Z")
        XCTAssertEqual(wave.activeConversationCount, 12)
        XCTAssertEqual(wave.lastParticipant?.id, "user-1")
        XCTAssertEqual(wave.lastParticipant?.name, "Maya")
    }

    func testMissingOrPartialDirectorySummaryCannotFailWholeWaveList() throws {
        let response = try JSONDecoder().decode(
            VibeWavesResponse.self,
            from: Data(
                """
                {
                  "waves":[
                    {"id":"legacy","name":"Legacy","slug":"legacy"},
                    {
                      "id":"partial",
                      "name":"Partial",
                      "slug":"partial",
                      "directorySummary":{"unreadCount":-2,"participant":null}
                    }
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(response.waves.count, 2)
        XCTAssertEqual(response.waves[0].unreadCount, 0)
        XCTAssertEqual(response.waves[1].unreadCount, 0)
        XCTAssertNil(response.waves[1].lastParticipant)
    }
}
