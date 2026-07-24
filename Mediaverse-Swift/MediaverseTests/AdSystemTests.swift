import XCTest
@testable import Mediaverse

final class AdBreakSchedulerTests: XCTestCase {
    func testFindsBreakCrossedByLargePlaybackJump() {
        let breaks = [
            AdBreak(id: "first", breakId: "first", timeOffsetSec: 30, placement: "midroll"),
            AdBreak(id: "second", breakId: "second", timeOffsetSec: 60, placement: "midroll")
        ]

        let due = AdBreakScheduler.nextDue(
            in: breaks,
            watchedIds: [],
            pendingIds: [],
            from: 10,
            to: 65
        )

        XCTAssertEqual(due?.id, "first")
    }

    func testIgnoresWatchedAndPendingBreaks() {
        let breaks = [
            AdBreak(id: "watched", breakId: "watched", timeOffsetSec: 20, placement: "midroll"),
            AdBreak(id: "pending", breakId: "pending", timeOffsetSec: 30, placement: "midroll"),
            AdBreak(id: "eligible", breakId: "eligible", timeOffsetSec: 40, placement: "midroll")
        ]

        let due = AdBreakScheduler.nextDue(
            in: breaks,
            watchedIds: ["watched"],
            pendingIds: ["pending"],
            from: 10,
            to: 45
        )

        XCTAssertEqual(due?.id, "eligible")
    }

    func testDoesNotScheduleWhileSeekingBackward() {
        let breaks = [
            AdBreak(id: "break", breakId: "break", timeOffsetSec: 30, placement: "midroll")
        ]

        XCTAssertNil(
            AdBreakScheduler.nextDue(
                in: breaks,
                watchedIds: [],
                pendingIds: [],
                from: 50,
                to: 20
            )
        )
    }
}

final class VMAPBreakParserTests: XCTestCase {
    func testParsesAbsolutePercentageAndEndOffsets() throws {
        let xml = """
        <vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap">
          <vmap:AdBreak breakId="midroll-absolute" timeOffset="00:00:30"/>
          <vmap:AdBreak breakId="midroll-percent" timeOffset="50%"/>
          <vmap:AdBreak breakId="postroll" timeOffset="end"/>
        </vmap:VMAP>
        """

        let breaks = try VMAPBreakParser.parse(Data(xml.utf8), durationSec: 120)

        XCTAssertEqual(breaks.map(\.timeOffsetSec), [30, 60, 120])
        XCTAssertEqual(breaks.map(\.placement), ["midroll", "midroll", "postroll"])
    }

    func testExcludesStartBecausePrerollUsesExplicitDecisionRequest() throws {
        let xml = """
        <VMAP>
          <AdBreak breakId="preroll" timeOffset="start"/>
          <AdBreak breakId="midroll" timeOffset="00:01:00"/>
        </VMAP>
        """

        let breaks = try VMAPBreakParser.parse(Data(xml.utf8), durationSec: 120)

        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks.first?.placement, "midroll")
    }

    func testRejectsMalformedXML() {
        XCTAssertThrowsError(
            try VMAPBreakParser.parse(Data("<VMAP><AdBreak".utf8), durationSec: 120)
        )
    }
}

final class SGAIPlaybackTests: XCTestCase {
    func testAdsDisabledAlwaysReturnsNone() {
        let policy = EffectiveAdPolicy.disabled(reason: "subscriber")
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .none)
    }

    func testNativeAppOverrideSelectsCSAI() throws {
        let data = Data(#"{"adsEnabled":true,"deliveryMode":"server","deliveryByDevice":{"nativeApp":"csai"}}"#.utf8)
        let policy = try JSONDecoder().decode(EffectiveAdPolicy.self, from: data)
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .csai)
    }

    func testAutoDefaultsToSGAIAndUnsupportedFallsBackToCSAI() throws {
        let policy = try JSONDecoder().decode(
            EffectiveAdPolicy.self,
            from: Data(#"{"adsEnabled":true,"deliveryByDevice":{"nativeApp":"auto"}}"#.utf8)
        )
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .sgai)
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy, supportsHLSInterstitials: false), .csai)
    }

    func testWrappedURLCarriesStablePlaybackAndContinuationContext() throws {
        let stream = try XCTUnwrap(URL(string: "https://example.com/manifest/video.m3u8?token=a+b"))
        let context = SGAIPlaybackContext(
            contentId: "video-1",
            contentType: "video",
            sessionId: "playback-uuid",
            userId: "user-1",
            deviceId: "device-1",
            country: "JO",
            orientation: "HORIZONTAL",
            entry: PlaybackEntryContext(
                surface: .homeFeed,
                mode: .autoplayPreview,
                contentStartSec: 12.5,
                previewSessionId: "preview-uuid"
            )
        )

        let wrapped = SGAIPlaybackURLBuilder.makeURL(streamMaster: stream, mode: .sgai, context: context)
        let components = try XCTUnwrap(URLComponents(url: wrapped, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(query["u"], stream.absoluteString)
        XCTAssertEqual(query["sessionId"], "playback-uuid")
        XCTAssertEqual(query["entrySurface"], "home_feed")
        XCTAssertEqual(query["entryMode"], "autoplay_preview")
        XCTAssertEqual(query["contentStartSec"], "12.5")
        XCTAssertEqual(query["previewSessionId"], "preview-uuid")
        XCTAssertNil(query["breaks"], "Break cadence must remain server-owned")
    }

    func testCSAILeavesContentURLUnchanged() throws {
        let stream = try XCTUnwrap(URL(string: "https://example.com/video.m3u8"))
        let context = SGAIPlaybackContext(
            contentId: "v",
            contentType: "video",
            sessionId: "s",
            userId: nil,
            deviceId: nil,
            country: nil,
            orientation: "HORIZONTAL",
            entry: .direct
        )
        XCTAssertEqual(
            SGAIPlaybackURLBuilder.makeURL(streamMaster: stream, mode: .csai, context: context),
            stream
        )
    }

    func testAssetListDecodingAndBreakIdentifier() throws {
        let data = Data("""
        {"ASSETS":[{
          "URI":"https://example.com/ad.m3u8",
          "DURATION":15,
          "X-WESTREEM-IID":"iid",
          "X-WESTREEM-DID":"did",
          "X-WESTREEM-SKIPPABLE":1,
          "X-WESTREEM-SKIP-OFFSET":5
        }]}
        """.utf8)

        let list = try JSONDecoder().decode(SGAIAssetList.self, from: data)
        XCTAssertEqual(list.assets.first?.impressionId, "iid")
        XCTAssertEqual(list.assets.first?.skipOffsetSec, 5)
        XCTAssertEqual(SGAIBreakIdentifier.breakId(from: "ad-midroll-2-0"), "midroll-2")
    }

    func testTrackingNeverFiresImpressionAndDeduplicatesEvents() {
        var state = SGAITrackingState()
        XCTAssertFalse(state.shouldFire(event: "impression", impressionId: "iid"))
        XCTAssertTrue(state.shouldFire(event: "start", impressionId: "iid"))
        XCTAssertFalse(state.shouldFire(event: "start", impressionId: "iid"))
        XCTAssertTrue(state.shouldFire(event: "complete", impressionId: "iid"))
        XCTAssertFalse(state.shouldFire(event: "start", impressionId: nil))
    }
}
