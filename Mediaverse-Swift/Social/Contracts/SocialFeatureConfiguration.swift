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

    public init(
        atmosphereEnabled: Bool = true,
        discoverEnabled: Bool = true,
        vibeDetailEnabled: Bool = true,
        rippleEngagementEnabled: Bool = true,
        rippleComposerEnabled: Bool = true,
        flashesEnergyEnabled: Bool = true
    ) {
        self.atmosphereEnabled = atmosphereEnabled
        self.discoverEnabled = discoverEnabled
        self.vibeDetailEnabled = vibeDetailEnabled
        self.rippleEngagementEnabled = rippleEngagementEnabled
        self.rippleComposerEnabled = rippleComposerEnabled
        self.flashesEnergyEnabled = flashesEnergyEnabled
    }

    public static let disabled = SocialFeatureConfiguration(
        atmosphereEnabled: false,
        discoverEnabled: false,
        vibeDetailEnabled: false,
        rippleEngagementEnabled: false,
        rippleComposerEnabled: false,
        flashesEnergyEnabled: false
    )

    /// Missing keys mean enabled; stored values always win.
    public static func runtime(userDefaults: UserDefaults = .standard) -> SocialFeatureConfiguration {
        SocialFeatureConfiguration(
            atmosphereEnabled: value(for: "social.atmosphere.enabled", in: userDefaults),
            discoverEnabled: value(for: "social.discover.enabled", in: userDefaults),
            vibeDetailEnabled: value(for: "social.vibe-detail.enabled", in: userDefaults),
            rippleEngagementEnabled: value(for: "social.ripple-engagement.enabled", in: userDefaults),
            rippleComposerEnabled: value(for: "social.ripple-composer.enabled", in: userDefaults),
            flashesEnergyEnabled: value(for: "social.flashes-energy.enabled", in: userDefaults)
        )
    }

    private static func value(for key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return true }
        return userDefaults.bool(forKey: key)
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
