import Foundation

/// Swift-owned rollout controls for the social layer.
///
/// These flags intentionally default to disabled so adding the social contracts
/// cannot alter the existing Home feed, Shorts, playback, advertising, or
/// navigation behavior before each native slice has passed parity QA.
public struct SocialFeatureConfiguration: Equatable, Sendable {
    public var atmosphereEnabled: Bool
    public var discoverEnabled: Bool
    public var vibeDetailEnabled: Bool
    public var rippleEngagementEnabled: Bool
    public var rippleComposerEnabled: Bool
    public var flashesEnergyEnabled: Bool

    public init(
        atmosphereEnabled: Bool = false,
        discoverEnabled: Bool = false,
        vibeDetailEnabled: Bool = false,
        rippleEngagementEnabled: Bool = false,
        rippleComposerEnabled: Bool = false,
        flashesEnergyEnabled: Bool = false
    ) {
        self.atmosphereEnabled = atmosphereEnabled
        self.discoverEnabled = discoverEnabled
        self.vibeDetailEnabled = vibeDetailEnabled
        self.rippleEngagementEnabled = rippleEngagementEnabled
        self.rippleComposerEnabled = rippleComposerEnabled
        self.flashesEnergyEnabled = flashesEnergyEnabled
    }

    public static let disabled = SocialFeatureConfiguration()

    /// Local rollout switch. Every key defaults to false, so installing this
    /// code cannot replace an existing surface until QA explicitly enables it.
    public static func runtime(userDefaults: UserDefaults = .standard) -> SocialFeatureConfiguration {
        SocialFeatureConfiguration(
            atmosphereEnabled: userDefaults.bool(forKey: "social.atmosphere.enabled"),
            discoverEnabled: userDefaults.bool(forKey: "social.discover.enabled"),
            vibeDetailEnabled: userDefaults.bool(forKey: "social.vibe-detail.enabled"),
            rippleEngagementEnabled: userDefaults.bool(forKey: "social.ripple-engagement.enabled"),
            rippleComposerEnabled: userDefaults.bool(forKey: "social.ripple-composer.enabled"),
            flashesEnergyEnabled: userDefaults.bool(forKey: "social.flashes-energy.enabled")
        )
    }

    public var hasAnyEnabledFeature: Bool {
        atmosphereEnabled ||
        discoverEnabled ||
        vibeDetailEnabled ||
        rippleEngagementEnabled ||
        rippleComposerEnabled ||
        flashesEnergyEnabled
    }
}
