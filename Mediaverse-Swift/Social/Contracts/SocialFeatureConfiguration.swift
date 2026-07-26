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

    public var hasAnyEnabledFeature: Bool {
        atmosphereEnabled ||
        discoverEnabled ||
        vibeDetailEnabled ||
        rippleEngagementEnabled ||
        rippleComposerEnabled ||
        flashesEnergyEnabled
    }
}
