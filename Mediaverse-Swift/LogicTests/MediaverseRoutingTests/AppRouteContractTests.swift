import XCTest
@testable import MediaverseRouting

final class AppRouteContractTests: XCTestCase {
    func testWebAndCustomSchemeVideoLinksResolveIdentically() {
        XCTAssertEqual(AppRoute.route(link: "https://westreem.com/watch/video-123"), .video("video-123"))
        XCTAssertEqual(AppRoute.route(link: "westreem://watch/video-123"), .video("video-123"))
    }

    func testShortRoutePreservesContextFromQuery() {
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/watch/short-1?type=short"),
            .short("short-1", showId: nil, channelId: nil)
        )
        XCTAssertEqual(
            AppRoute.route(link: "westreem://open?shortId=short-1&showId=show-2&channelId=channel-3"),
            .short("short-1", showId: "show-2", channelId: "channel-3")
        )
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/watch/short-1?type=short&showId=show-2&channelId=channel-3"),
            .short("short-1", showId: "show-2", channelId: "channel-3")
        )
    }

    func testConcretePathBeatsGenericContextQuery() {
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/watch/short-9?type=short&showId=show-context"),
            .short("short-9", showId: "show-context", channelId: nil)
        )
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/watch/video-9?showId=show-context"),
            .video("video-9")
        )
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/channel/path-channel?channelId=context-channel"),
            .channel("path-channel")
        )
    }

    func testEpisodeAndMicrodramaPathsResolve() {
        XCTAssertEqual(AppRoute.route(link: "/watch/episode/episode-7"), .episode("episode-7"))
        XCTAssertEqual(
            AppRoute.route(link: "/microdramas/drama-4/episodes/9"),
            .microdramaWatchEp("drama-4", 9)
        )
    }

    func testSocialWebLinksResolveToNativeDestinations() {
        XCTAssertEqual(AppRoute.route(link: "/vibes/cinema"), .vibe("cinema"))
        XCTAssertEqual(
            AppRoute.route(link: "https://www.westreem.com/vibes/invite/opaque%20token"),
            .vibeInvite("opaque token")
        )
        XCTAssertEqual(
            AppRoute.route(link: "https://www.westreem.com/vibes/cinema/posts/ripple-7"),
            .ripple("ripple-7")
        )
        XCTAssertEqual(AppRoute.route(link: "/atmo/ahmed"), .atmo("ahmed"))
        XCTAssertEqual(AppRoute.route(link: "/ripples/ripple-8"), .ripple("ripple-8"))
        XCTAssertEqual(AppRoute.route(link: "/discover?topic=cinema"), .search("cinema"))
        XCTAssertEqual(
            AppRoute.route(link: "/vibes/cinema/manage?tab=affiliations"),
            .vibeManagement(slug: "cinema", tab: "affiliations")
        )
        XCTAssertEqual(
            AppRoute.route(link: "/vibes/cinema/manage?tab=requests"),
            .vibeManagement(slug: "cinema", tab: "requests")
        )
        XCTAssertEqual(AppRoute.route(link: "westreem://vibe/cinema"), .vibe("cinema"))
        XCTAssertEqual(AppRoute.route(link: "/fan-clubs/cinema/posts/ripple-9"), .ripple("ripple-9"))
        XCTAssertEqual(AppRoute.route(link: "/glow/@ahmed"), .atmo("ahmed"))
        XCTAssertEqual(AppRoute.route(link: "westreem://event/premiere-night"), .event("premiere-night"))
        XCTAssertEqual(AppRoute.route(link: "/stories/flash-12"), .flash("flash-12"))
    }

    func testSocialNotificationIdentifiersResolveWithoutFullURL() {
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "ripple_energy", "ripple_id": "ripple-11"]),
            .ripple("ripple-11")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "vibe_affiliation_approved", "vibe_slug": "cinema"]),
            .vibeManagement(slug: "cinema", tab: "affiliations")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "vibe_join_request", "club_slug": "cinema"]),
            .vibeManagement(slug: "cinema", tab: "requests")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "vibe_event_invite", "event_invite_token": "secret"]),
            .eventInvite("secret")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "mention", "user_handle": "@ahmed"]),
            .atmo("ahmed")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "flash_energy", "story_id": "flash-12"]),
            .flash("flash-12")
        )
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: ["type": "vibe_new_ripple", "vibe_slug": "cinema", "wave_slug": "events"]),
            .vibeWave(vibeSlug: "cinema", waveSlug: "events")
        )
    }

    func testWaveLinksPreserveVibeAndWaveIdentity() {
        XCTAssertEqual(
            AppRoute.route(link: "https://westreem.com/vibes/cinema/waves/events"),
            .vibeWave(vibeSlug: "cinema", waveSlug: "events")
        )
        XCTAssertEqual(
            AppRoute.route(link: "westreem://vibes/cinema/waves/questions"),
            .vibeWave(vibeSlug: "cinema", waveSlug: "questions")
        )
        XCTAssertNotEqual(
            AppRoute.vibeWave(vibeSlug: "cinema", waveSlug: "events").id,
            AppRoute.vibeWave(vibeSlug: "cinema", waveSlug: "questions").id
        )
    }

    func testNotificationPayloadPrecedence() {
        let payload: [AnyHashable: Any] = [
            "type": "short",
            "short_id": "short-8",
            "video_id": "video-that-must-not-win",
            "show_id": "show-5"
        ]
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: payload),
            .short("short-8", showId: "show-5", channelId: nil)
        )
    }

    func testNotificationStringifiesNumericEpisodeNumber() {
        let payload: [AnyHashable: Any] = [
            "microdrama_id": "drama-1",
            "episode_number": 6
        ]
        XCTAssertEqual(
            AppRoute.notificationRoute(userInfo: payload),
            .microdramaWatchEp("drama-1", 6)
        )
    }

    func testDistinctContextualShortsHaveDistinctIdentity() {
        XCTAssertNotEqual(
            AppRoute.short("same", showId: "show-a", channelId: nil).id,
            AppRoute.short("same", showId: "show-b", channelId: nil).id
        )
    }

    func testSeasonRoutesPreserveShowAndSeasonIdentity() {
        XCTAssertNotEqual(
            AppRoute.showSeason(showId: "show-1", seasonId: "season-1").id,
            AppRoute.showSeason(showId: "show-1", seasonId: "season-2").id
        )
    }

    func testUnknownAndEmptyLinksDoNotInventDestinations() {
        XCTAssertNil(AppRoute.route(link: ""))
        XCTAssertNil(AppRoute.route(link: "https://westreem.com/settings/account"))
    }
}
