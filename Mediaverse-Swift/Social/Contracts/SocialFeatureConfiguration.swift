import Foundation

/// Swift-owned rollout controls for the social layer.
///
/// Features default on for clean installs. An explicitly stored false value is
/// an emergency local kill switch and does not alter backend contracts.
public struct SocialFeatureConfiguration: Equatable, Sendable {
    public var atmosphereEnabled: Bool
    public var discoverEnabled: Bool
    public var vibeDetailEnabled: Bool
    public var rippleEngagementEnabled: Bool
    public var rippleComposerEnabled: Bool
    public var flashesEnergyEnabled: Bool
    /// Matrix-backed realtime transport remains server-gated. Local defaults
    /// are enabled for the production client now that the rollout endpoints
    /// are live; an explicitly stored false remains the device kill switch.
    public var matrixRealtimeEnabled: Bool
    /// Matrix-native Vibes is the production community client. Missing local
    /// storage enables the client; an explicitly stored false remains the
    /// emergency device kill switch. Matrix session startup still requires
    /// the server's ownership-v2 capability response.
    public var matrixNativeVibesEnabled: Bool
    /// Personal Atmo v2 remains a Westreem API cutover and is independent
    /// from community Vibes/Matrix. Missing storage must remain disabled.
    public var personalAtmoV2Enabled: Bool
    public var wavePresenceEnabled: Bool
    public var directMessagesEnabled: Bool
    public var voiceRipplesEnabled: Bool
    public var videoRipplesEnabled: Bool
    public var liveEventRoomsEnabled: Bool
    public var watchPartiesEnabled: Bool

    public init(
        atmosphereEnabled: Bool = true,
        discoverEnabled: Bool = true,
        vibeDetailEnabled: Bool = true,
        rippleEngagementEnabled: Bool = true,
        rippleComposerEnabled: Bool = true,
        flashesEnergyEnabled: Bool = true,
        matrixRealtimeEnabled: Bool = false,
        matrixNativeVibesEnabled: Bool = false,
        personalAtmoV2Enabled: Bool = false,
        wavePresenceEnabled: Bool = false,
        directMessagesEnabled: Bool = false,
        voiceRipplesEnabled: Bool = false,
        videoRipplesEnabled: Bool = false,
        liveEventRoomsEnabled: Bool = false,
        watchPartiesEnabled: Bool = false
    ) {
        self.atmosphereEnabled = atmosphereEnabled
        self.discoverEnabled = discoverEnabled
        self.vibeDetailEnabled = vibeDetailEnabled
        self.rippleEngagementEnabled = rippleEngagementEnabled
        self.rippleComposerEnabled = rippleComposerEnabled
        self.flashesEnergyEnabled = flashesEnergyEnabled
        self.matrixRealtimeEnabled = matrixRealtimeEnabled
        self.matrixNativeVibesEnabled = matrixNativeVibesEnabled
        self.personalAtmoV2Enabled = personalAtmoV2Enabled
        self.wavePresenceEnabled = wavePresenceEnabled
        self.directMessagesEnabled = directMessagesEnabled
        self.voiceRipplesEnabled = voiceRipplesEnabled
        self.videoRipplesEnabled = videoRipplesEnabled
        self.liveEventRoomsEnabled = liveEventRoomsEnabled
        self.watchPartiesEnabled = watchPartiesEnabled
    }

    public static let disabled = SocialFeatureConfiguration(
        atmosphereEnabled: false,
        discoverEnabled: false,
        vibeDetailEnabled: false,
        rippleEngagementEnabled: false,
        rippleComposerEnabled: false,
        flashesEnergyEnabled: false,
        matrixRealtimeEnabled: false,
        matrixNativeVibesEnabled: false,
        personalAtmoV2Enabled: false,
        wavePresenceEnabled: false,
        directMessagesEnabled: false,
        voiceRipplesEnabled: false,
        videoRipplesEnabled: false,
        liveEventRoomsEnabled: false,
        watchPartiesEnabled: false
    )

    /// Missing keys mean enabled; stored values always win.
    public static func runtime(userDefaults: UserDefaults = .standard) -> SocialFeatureConfiguration {
        SocialFeatureConfiguration(
            atmosphereEnabled: value(for: "social.atmosphere.enabled", in: userDefaults),
            discoverEnabled: value(for: "social.discover.enabled", in: userDefaults),
            vibeDetailEnabled: value(for: "social.vibe-detail.enabled", in: userDefaults),
            rippleEngagementEnabled: value(for: "social.ripple-engagement.enabled", in: userDefaults),
            rippleComposerEnabled: value(for: "social.ripple-composer.enabled", in: userDefaults),
            flashesEnergyEnabled: value(for: "social.flashes-energy.enabled", in: userDefaults),
            matrixRealtimeEnabled: optInValue(for: "social.matrix-realtime.enabled", in: userDefaults),
            matrixNativeVibesEnabled: optInValue(
                for: "social.matrix-native-vibes-v2.enabled",
                in: userDefaults
            ),
            personalAtmoV2Enabled: strictOptInValue(
                for: "social.personal-atmo-v2.enabled",
                in: userDefaults
            ),
            wavePresenceEnabled: optInValue(for: "social.wave-presence.enabled", in: userDefaults),
            directMessagesEnabled: optInValue(for: "social.direct-messages.enabled", in: userDefaults),
            voiceRipplesEnabled: optInValue(for: "social.voice-ripples.enabled", in: userDefaults),
            videoRipplesEnabled: optInValue(for: "social.video-ripples.enabled", in: userDefaults),
            liveEventRoomsEnabled: optInValue(for: "social.live-event-rooms.enabled", in: userDefaults),
            watchPartiesEnabled: optInValue(for: "social.watch-parties.enabled", in: userDefaults)
        )
    }

    private static func value(for key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return true }
        return userDefaults.bool(forKey: key)
    }

    private static func optInValue(for key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return true }
        return userDefaults.bool(forKey: key)
    }

    public var hasAnyEnabledFeature: Bool {
        atmosphereEnabled ||
        discoverEnabled ||
        vibeDetailEnabled ||
        rippleEngagementEnabled ||
        rippleComposerEnabled ||
        flashesEnergyEnabled ||
        matrixRealtimeEnabled ||
        matrixNativeVibesEnabled ||
        personalAtmoV2Enabled ||
        wavePresenceEnabled ||
        directMessagesEnabled ||
        voiceRipplesEnabled ||
        videoRipplesEnabled ||
        liveEventRoomsEnabled ||
        watchPartiesEnabled
    }

    private static func strictOptInValue(for key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return false }
        return userDefaults.bool(forKey: key)
    }
}
