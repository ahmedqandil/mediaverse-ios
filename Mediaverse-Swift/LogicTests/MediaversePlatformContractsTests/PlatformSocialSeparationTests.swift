import XCTest
@testable import MediaversePlatformContracts

final class PlatformSocialSeparationTests: XCTestCase {
    func testAtmosphereAndMatrixVibesDecodeAsIndependentSections() throws {
        let payload = """
        {
          "sections": {
            "browse": {
              "sections": [
                {
                  "id": "atmosphere",
                  "label": "The Atmosphere",
                  "enabled": true,
                  "nav": false,
                  "page": true,
                  "feed": false,
                  "search": false,
                  "creation": true
                },
                {
                  "id": "vibes",
                  "label": "Vibes",
                  "enabled": true,
                  "nav": true,
                  "page": true,
                  "feed": true,
                  "search": true,
                  "creation": false
                },
                {
                  "id": "people",
                  "label": "People",
                  "enabled": true,
                  "nav": false,
                  "page": true,
                  "feed": false,
                  "search": false,
                  "creation": true
                }
              ]
            }
          }
        }
        """

        let config = try JSONDecoder().decode(
            PlatformConfig.self,
            from: try XCTUnwrap(payload.data(using: .utf8))
        )
        let atmosphere = try XCTUnwrap(
            config.sections.browse.sections.first { $0.id == "atmosphere" }
        )
        let vibes = try XCTUnwrap(
            config.sections.browse.sections.first { $0.id == "vibes" }
        )
        let people = try XCTUnwrap(
            config.sections.browse.sections.first { $0.id == "people" }
        )

        XCTAssertFalse(atmosphere.nav)
        XCTAssertFalse(atmosphere.feed)
        XCTAssertFalse(atmosphere.search)
        XCTAssertTrue(atmosphere.page)
        XCTAssertTrue(vibes.nav)
        XCTAssertTrue(vibes.feed)
        XCTAssertTrue(vibes.search)
        XCTAssertFalse(vibes.creation)
        XCTAssertEqual(people.search, atmosphere.search)
        XCTAssertNotEqual(people.search, vibes.search)
    }

    func testDefaultRegistryContainsBothAuthorities() {
        let ids = PlatformBrowseItem.defaults.map(\.id)
        XCTAssertTrue(ids.contains("atmosphere"))
        XCTAssertTrue(ids.contains("vibes"))
        XCTAssertNotEqual(
            PlatformBrowseItem.normalizedId("the-atmosphere"),
            PlatformBrowseItem.normalizedId("vibes")
        )
    }
}
