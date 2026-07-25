import Foundation

struct PlatformConfig: Decodable {
    let sections: PlatformSections
    let ads: PlatformAdsConfig

    static let `default` = PlatformConfig(sections: .default, ads: .default)

    private enum CodingKeys: String, CodingKey {
        case sections, ads, adConfig, advertising
    }

    init(sections: PlatformSections, ads: PlatformAdsConfig) {
        self.sections = sections
        self.ads = ads
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent(PlatformSections.self, forKey: .sections) ?? .default
        ads = try container.decodeIfPresent(PlatformAdsConfig.self, forKey: .ads)
            ?? container.decodeIfPresent(PlatformAdsConfig.self, forKey: .adConfig)
            ?? container.decodeIfPresent(PlatformAdsConfig.self, forKey: .advertising)
            ?? .default
    }

    var storiesFeedEnabled: Bool {
        sections.stories.feed
    }

    var browseSections: [PlatformBrowseItem] {
        sections.browse.sections
    }
}

struct PlatformAdsConfig: Decodable {
    let shorts: PlatformShortsAdsConfig
    let video: PlatformShortsAdsConfig
    let episode: PlatformShortsAdsConfig

    static let `default` = PlatformAdsConfig(shorts: .default, video: .videoDefault, episode: .episodeDefault)

    private enum CodingKeys: String, CodingKey {
        case shorts, short, shortsAds, shortAds, shortsFeed
        case video, videos, videoAds
        case episode, episodes, episodeAds
    }

    init(shorts: PlatformShortsAdsConfig, video: PlatformShortsAdsConfig, episode: PlatformShortsAdsConfig) {
        self.shorts = shorts
        self.video = video
        self.episode = episode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shorts = try container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .shorts)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .short)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .shortsAds)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .shortAds)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .shortsFeed)
            ?? .default
        video = (try container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .video)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .videos)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .videoAds)
            ?? .videoDefault)
            .applyingDefaultPlacements(PlatformShortsAdsConfig.longformDefaultPlacements)
        episode = (try container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .episode)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .episodes)
            ?? container.decodeIfPresent(PlatformShortsAdsConfig.self, forKey: .episodeAds)
            ?? .episodeDefault)
            .applyingDefaultPlacements(PlatformShortsAdsConfig.longformDefaultPlacements)
    }
}

struct PlatformShortsAdsConfig: Decodable {
    let enabled: Bool
    let cadenceKind: String
    let cadenceValue: Int
    let firstAfter: Int
    let skippable: Bool?
    let skipAfterSec: Int?
    let maxAds: Int?
    let maxDurationSec: Int?
    let placements: [String: PlatformAdPlacementConfig]

    static let `default` = PlatformShortsAdsConfig(
        enabled: true,
        cadenceKind: "count",
        cadenceValue: 5,
        firstAfter: 3,
        skippable: false,
        skipAfterSec: 0,
        maxAds: 1,
        maxDurationSec: nil,
        placements: [
            "shorts_first_view": .shortsFirstViewDefault,
            "shorts_feed": .shortsFeedDefault
        ]
    )

    static let disabled = PlatformShortsAdsConfig(
        enabled: false,
        cadenceKind: "count",
        cadenceValue: 0,
        firstAfter: 0,
        skippable: false,
        skipAfterSec: 0,
        maxAds: 0,
        maxDurationSec: nil,
        placements: [:]
    )

    static let videoDefault = PlatformShortsAdsConfig.longformDefault()
    static let episodeDefault = PlatformShortsAdsConfig.longformDefault()
    static let longformDefaultPlacements: [String: PlatformAdPlacementConfig] = [
        "preroll": .prerollDefault,
        "midroll": .midrollDefault
    ]

    private static func longformDefault() -> PlatformShortsAdsConfig {
        PlatformShortsAdsConfig(
            enabled: true,
            cadenceKind: "time",
            cadenceValue: 600,
            firstAfter: 0,
            skippable: true,
            skipAfterSec: 5,
            maxAds: 1,
            maxDurationSec: nil,
            placements: longformDefaultPlacements
        )
    }

    enum CodingKeys: String, CodingKey {
        case enabled, visible, feed, adsEnabled
        case cadenceKind, kind, cadenceType
        case cadenceValue, every, interval, frequency, adEvery, adsEvery, showEvery, everyN
        case firstAfter, firstAfterCount, firstAdAfter, firstAdAfterCount
        case skippable
        case skipAfterSec, skipAfter, skipOffsetSec
        case maxAds, maxAdsPerBreak, adLoad
        case maxDurationSec, maxDuration, maxAdDurationSec
        case placements, placementConfigs, adPlacements
    }

    init(
        enabled: Bool,
        cadenceKind: String,
        cadenceValue: Int,
        firstAfter: Int,
        skippable: Bool?,
        skipAfterSec: Int?,
        maxAds: Int?,
        maxDurationSec: Int?,
        placements: [String: PlatformAdPlacementConfig] = [:]
    ) {
        self.enabled = enabled
        self.cadenceKind = cadenceKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.cadenceValue = max(0, cadenceValue)
        self.firstAfter = max(0, firstAfter)
        self.skippable = skippable
        self.skipAfterSec = skipAfterSec.map { max(0, $0) }
        self.maxAds = maxAds.map { max(1, $0) }
        self.maxDurationSec = maxDurationSec.map { max(1, $0) }
        self.placements = placements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .adsEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .visible)
            ?? container.decodeIfPresent(Bool.self, forKey: .feed)
            ?? true
        let cadenceKind = try container.decodeIfPresent(String.self, forKey: .cadenceKind)
            ?? container.decodeIfPresent(String.self, forKey: .kind)
            ?? container.decodeIfPresent(String.self, forKey: .cadenceType)
            ?? "count"
        let cadenceValue = Self.decodeInt(from: container, keys: [.cadenceValue, .every, .interval, .frequency, .adEvery, .adsEvery, .showEvery, .everyN]) ?? 5
        let firstAfter = Self.decodeInt(from: container, keys: [.firstAfter, .firstAfterCount, .firstAdAfter, .firstAdAfterCount]) ?? 3
        let skipAfterSec = Self.decodeInt(from: container, keys: [.skipAfterSec, .skipAfter, .skipOffsetSec])
        let maxAds = Self.decodeInt(from: container, keys: [.maxAds, .maxAdsPerBreak, .adLoad])
        let maxDurationSec = Self.decodeInt(from: container, keys: [.maxDurationSec, .maxDuration, .maxAdDurationSec])
        let skippable = try container.decodeIfPresent(Bool.self, forKey: .skippable)
        var placements = Self.default.placements
        for (key, placement) in Self.decodePlacements(from: container) {
            placements[key] = placement
        }

        self.init(
            enabled: enabled,
            cadenceKind: cadenceKind,
            cadenceValue: cadenceValue,
            firstAfter: firstAfter,
            skippable: skippable,
            skipAfterSec: skipAfterSec,
            maxAds: maxAds,
            maxDurationSec: maxDurationSec,
            placements: placements
        )
    }

    func placementConfig(for key: String) -> PlatformAdPlacementConfig {
        placements[key] ?? .default
    }

    func withPlacements(_ placements: [PlatformAdPlacementConfig]) -> PlatformShortsAdsConfig {
        var map = self.placements
        for placement in placements {
            map[placement.placementKey] = placement
        }
        return replacingPlacements(map)
    }

    func applyingDefaultPlacements(_ defaultPlacements: [String: PlatformAdPlacementConfig]) -> PlatformShortsAdsConfig {
        var map = defaultPlacements
        for (key, placement) in placements {
            map[key] = placement
        }
        return replacingPlacements(map)
    }

    private func replacingPlacements(_ placements: [String: PlatformAdPlacementConfig]) -> PlatformShortsAdsConfig {
        PlatformShortsAdsConfig(
            enabled: enabled,
            cadenceKind: cadenceKind,
            cadenceValue: cadenceValue,
            firstAfter: firstAfter,
            skippable: skippable,
            skipAfterSec: skipAfterSec,
            maxAds: maxAds,
            maxDurationSec: maxDurationSec,
            placements: placements
        )
    }

    fileprivate static func decodeInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue
            }
            if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(doubleValue)
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key),
               let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }
        return nil
    }

    fileprivate static func decodePlacements(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: PlatformAdPlacementConfig] {
        var map: [String: PlatformAdPlacementConfig] = [:]
        let keys: [CodingKeys] = [.placements, .placementConfigs, .adPlacements]

        for key in keys {
            if let placements = try? container.decodeIfPresent([PlatformAdPlacementConfig].self, forKey: key) {
                for placement in placements where !placement.placementKey.isEmpty {
                    map[placement.placementKey] = placement
                }
            }

            if let placements = try? container.decodeIfPresent([String: PlatformAdPlacementConfig].self, forKey: key) {
                for (placementKey, placement) in placements {
                    let normalizedKey = placement.placementKey.isEmpty ? placementKey : placement.placementKey
                    guard !normalizedKey.isEmpty else { continue }
                    map[normalizedKey] = PlatformAdPlacementConfig(
                        placementKey: normalizedKey,
                        enabled: placement.enabled,
                        skippable: placement.skippable,
                        skipAfterSec: placement.skipAfterSec,
                        maxDurationSec: placement.maxDurationSec,
                        frequencyPerUserPerDay: placement.frequencyPerUserPerDay
                    )
                }
            }
        }

        return map
    }
}

struct PlatformAdPlacementConfig: Decodable {
    let placementKey: String
    let enabled: Bool
    let skippable: Bool?
    let skipAfterSec: Int?
    let maxDurationSec: Int?
    let frequencyPerUserPerDay: Int?

    static let `default` = PlatformAdPlacementConfig(
        placementKey: "",
        enabled: true,
        skippable: nil,
        skipAfterSec: nil,
        maxDurationSec: nil,
        frequencyPerUserPerDay: nil
    )

    static let shortsFirstViewDefault = PlatformAdPlacementConfig(
        placementKey: "shorts_first_view",
        enabled: true,
        skippable: true,
        skipAfterSec: 5,
        maxDurationSec: 20,
        frequencyPerUserPerDay: 1
    )

    static let shortsFeedDefault = PlatformAdPlacementConfig(
        placementKey: "shorts_feed",
        enabled: true,
        skippable: false,
        skipAfterSec: 0,
        maxDurationSec: 15,
        frequencyPerUserPerDay: nil
    )

    static let prerollDefault = PlatformAdPlacementConfig(
        placementKey: "preroll",
        enabled: true,
        skippable: true,
        skipAfterSec: 5,
        maxDurationSec: nil,
        frequencyPerUserPerDay: nil
    )

    static let midrollDefault = PlatformAdPlacementConfig(
        placementKey: "midroll",
        enabled: true,
        skippable: true,
        skipAfterSec: 5,
        maxDurationSec: nil,
        frequencyPerUserPerDay: nil
    )

    private enum CodingKeys: String, CodingKey {
        case placementKey, key, placement, id
        case enabled, visible
        case skippable
        case skipAfterSec, skipAfter, skipOffsetSec
        case maxDurationSec, maxDuration, maxAdDurationSec
        case frequencyPerUserPerDay, dailyFrequencyCap
    }

    init(
        placementKey: String,
        enabled: Bool,
        skippable: Bool?,
        skipAfterSec: Int?,
        maxDurationSec: Int?,
        frequencyPerUserPerDay: Int?
    ) {
        self.placementKey = placementKey
        self.enabled = enabled
        self.skippable = skippable
        self.skipAfterSec = skipAfterSec.map { max(0, $0) }
        self.maxDurationSec = maxDurationSec.map { max(1, $0) }
        self.frequencyPerUserPerDay = frequencyPerUserPerDay.map { max(0, $0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let placementKey = try container.decodeIfPresent(String.self, forKey: .placementKey)
            ?? container.decodeIfPresent(String.self, forKey: .key)
            ?? container.decodeIfPresent(String.self, forKey: .placement)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .visible)
            ?? true
        let skippable = try container.decodeIfPresent(Bool.self, forKey: .skippable)
        let skipAfterSec = Self.decodeInt(from: container, keys: [.skipAfterSec, .skipAfter, .skipOffsetSec])
        let maxDurationSec = Self.decodeInt(from: container, keys: [.maxDurationSec, .maxDuration, .maxAdDurationSec])
        let frequency = Self.decodeInt(from: container, keys: [.frequencyPerUserPerDay, .dailyFrequencyCap])
        self.init(
            placementKey: placementKey,
            enabled: enabled,
            skippable: skippable,
            skipAfterSec: skipAfterSec,
            maxDurationSec: maxDurationSec,
            frequencyPerUserPerDay: frequency
        )
    }

    private static func decodeInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) { return intValue }
            if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(doubleValue) }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key),
               let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }
        return nil
    }
}

struct AdminAdConfig: Decodable {
    let shorts: PlatformShortsAdsConfig
    let video: PlatformShortsAdsConfig
    let episode: PlatformShortsAdsConfig

    private enum CodingKeys: String, CodingKey {
        case typeConfigs, types, adTypes, placements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeConfigs = try container.decodeIfPresent([AdminAdTypeConfig].self, forKey: .typeConfigs)
            ?? container.decodeIfPresent([AdminAdTypeConfig].self, forKey: .types)
            ?? container.decodeIfPresent([AdminAdTypeConfig].self, forKey: .adTypes)
            ?? []
        let placementConfigs = try container.decodeIfPresent([PlatformAdPlacementConfig].self, forKey: .placements) ?? []
        let shortType = typeConfigs.first { $0.contentType == "short" }
        let videoType = typeConfigs.first { $0.contentType == "video" }
        let episodeType = typeConfigs.first { $0.contentType == "episode" }

        shorts = (shortType?.config ?? .default).withPlacements(
            placementConfigs.filter { $0.placementKey == "shorts_first_view" || $0.placementKey == "shorts_feed" }
        )
        video = (videoType?.config ?? .videoDefault).withPlacements(
            placementConfigs.filter { $0.placementKey == "preroll" || $0.placementKey == "midroll" || $0.placementKey.hasPrefix("video_") }
        )
        episode = (episodeType?.config ?? .episodeDefault).withPlacements(
            placementConfigs.filter { $0.placementKey == "preroll" || $0.placementKey == "midroll" || $0.placementKey.hasPrefix("episode_") }
        )
    }
}

private struct AdminAdTypeConfig: Decodable {
    let contentType: String
    let config: PlatformShortsAdsConfig

    private enum CodingKeys: String, CodingKey {
        case contentType, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlatformShortsAdsConfig.CodingKeys.self)
        let typedContainer = try decoder.container(keyedBy: CodingKeys.self)
        contentType = try (typedContainer.decodeIfPresent(String.self, forKey: .contentType)
            ?? typedContainer.decodeIfPresent(String.self, forKey: .type)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let fallback: PlatformShortsAdsConfig
        switch contentType {
        case "video":
            fallback = .videoDefault
        case "episode":
            fallback = .episodeDefault
        default:
            fallback = .default
        }

        let enabled = try container.decodeIfPresent(Bool.self, forKey: .adsEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? fallback.enabled
        let cadenceKind = try container.decodeIfPresent(String.self, forKey: .cadenceKind) ?? fallback.cadenceKind
        let cadenceValue = PlatformShortsAdsConfig.decodeInt(from: container, keys: [.cadenceValue]) ?? fallback.cadenceValue
        let firstAfter = PlatformShortsAdsConfig.decodeInt(from: container, keys: [.firstAfter]) ?? fallback.firstAfter
        let skipAfterSec = PlatformShortsAdsConfig.decodeInt(from: container, keys: [.skipAfterSec]) ?? fallback.skipAfterSec
        let maxAds = PlatformShortsAdsConfig.decodeInt(from: container, keys: [.adLoad, .maxAds]) ?? fallback.maxAds
        let maxDurationSec = PlatformShortsAdsConfig.decodeInt(from: container, keys: [.maxDurationSec, .maxAdDurationSec]) ?? fallback.maxDurationSec
        let skippable = try container.decodeIfPresent(Bool.self, forKey: .skippable) ?? fallback.skippable
        var placements = fallback.placements
        for (key, placement) in PlatformShortsAdsConfig.decodePlacements(from: container) {
            placements[key] = placement
        }
        config = PlatformShortsAdsConfig(
            enabled: enabled,
            cadenceKind: cadenceKind,
            cadenceValue: cadenceValue,
            firstAfter: firstAfter,
            skippable: skippable,
            skipAfterSec: skipAfterSec,
            maxAds: maxAds,
            maxDurationSec: maxDurationSec,
            placements: placements
        )
    }
}

struct PlatformSections: Decodable {
    let stories: PlatformStorySection
    let browse: PlatformBrowseSection

    static let `default` = PlatformSections(stories: .default, browse: .default)

    enum CodingKeys: String, CodingKey {
        case stories, browse, shows, videos, movies, microdramas, channels, following, collections
    }

    init(stories: PlatformStorySection, browse: PlatformBrowseSection) {
        self.stories = stories
        self.browse = browse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stories = try container.decodeIfPresent(PlatformStorySection.self, forKey: .stories) ?? .default
        let decodedBrowse = try container.decodeIfPresent(PlatformBrowseSection.self, forKey: .browse) ?? .default
        browse = decodedBrowse.applyingOverrides(from: container)
    }
}

struct PlatformStorySection: Decodable {
    let feed: Bool

    static let `default` = PlatformStorySection(feed: true)

    private enum CodingKeys: String, CodingKey {
        case feed
    }

    init(feed: Bool) {
        self.feed = feed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feed = try container.decodeIfPresent(Bool.self, forKey: .feed) ?? true
    }
}

struct PlatformBrowseSection: Decodable {
    let sections: [PlatformBrowseItem]

    static let `default` = PlatformBrowseSection(sections: PlatformBrowseItem.defaults)

    private enum CodingKeys: String, CodingKey {
        case sections, items, order, shows, videos, movies, microdramas, channels, following, collections
    }

    init(sections: [PlatformBrowseItem]) {
        self.sections = sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let sections = try container.decodeIfPresent([PlatformBrowseItem].self, forKey: .sections) {
            self.sections = Self.normalized(sections)
            return
        }

        if let items = try container.decodeIfPresent([PlatformBrowseItem].self, forKey: .items) {
            self.sections = Self.normalized(items)
            return
        }

        let order = (try container.decodeIfPresent([String].self, forKey: .order)) ?? PlatformBrowseItem.defaults.map(\.id)
        self.sections = Self.sections(from: order, container: container)
    }

    func applyingOverrides(from container: KeyedDecodingContainer<PlatformSections.CodingKeys>) -> PlatformBrowseSection {
        let mapped = sections.compactMap { item -> PlatformBrowseItem? in
            guard let override = try? container.decodeIfPresent(PlatformSectionToggle.self, forKey: PlatformSections.CodingKeys(stringValue: item.id) ?? .shows) else {
                return item
            }
            return item.withOverride(override)
        }
        return PlatformBrowseSection(sections: Self.normalized(mapped))
    }

    private static func sections(from order: [String], container: KeyedDecodingContainer<CodingKeys>) -> [PlatformBrowseItem] {
        normalized(order.compactMap { rawId in
            let id = PlatformBrowseItem.normalizedId(rawId)
            guard let base = PlatformBrowseItem.defaultItem(for: id) else { return nil }
            let key = CodingKeys(stringValue: id) ?? .shows
            let override = try? container.decodeIfPresent(PlatformSectionToggle.self, forKey: key)
            return base.withOverride(override)
        })
    }

    private static func normalized(_ sections: [PlatformBrowseItem]) -> [PlatformBrowseItem] {
        var seen = Set<String>()
        return sections
            .filter(\.enabled)
            .compactMap { item in
                guard PlatformBrowseItem.defaultItem(for: item.id) != nil, !seen.contains(item.id) else { return nil }
                seen.insert(item.id)
                return item
            }
    }
}

struct PlatformBrowseItem: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let enabled: Bool

    static let defaults: [PlatformBrowseItem] = [
        PlatformBrowseItem(id: "shows", label: "Shows", enabled: true),
        PlatformBrowseItem(id: "videos", label: "Videos", enabled: true),
        PlatformBrowseItem(id: "movies", label: "Movies", enabled: true),
        PlatformBrowseItem(id: "microdramas", label: "Microdramas", enabled: true),
        PlatformBrowseItem(id: "channels", label: "Channels", enabled: true),
        PlatformBrowseItem(id: "following", label: "Following", enabled: true),
        PlatformBrowseItem(id: "collections", label: "Collections", enabled: true),
    ]

    private enum CodingKeys: String, CodingKey {
        case id, type, key, slug, label, title, name, enabled, visible, page, feed
    }

    init(id: String, label: String, enabled: Bool) {
        self.id = Self.normalizedId(id)
        self.label = label
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(String.self) {
            let normalizedId = Self.normalizedId(id)
            let base = Self.defaultItem(for: normalizedId)
            self.init(id: normalizedId, label: base?.label ?? id, enabled: true)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .key)
            ?? container.decodeIfPresent(String.self, forKey: .slug)
            ?? ""
        let normalizedId = Self.normalizedId(rawId)
        let base = Self.defaultItem(for: normalizedId)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? base?.label
            ?? rawId
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .visible)
            ?? container.decodeIfPresent(Bool.self, forKey: .page)
            ?? container.decodeIfPresent(Bool.self, forKey: .feed)
            ?? true
        self.init(id: normalizedId, label: label, enabled: enabled)
    }

    func withOverride(_ override: PlatformSectionToggle?) -> PlatformBrowseItem? {
        guard let override else { return self }
        let nextLabel = override.label ?? label
        return PlatformBrowseItem(id: id, label: nextLabel, enabled: override.enabled)
    }

    static func normalizedId(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "tv", "series", "shows-series", "tv-shows":
            return "shows"
        case "video", "videos", "watch-videos", "all-videos":
            return "videos"
        case "movie", "films", "film":
            return "movies"
        case "microdrama", "micro-drama", "micro-drams", "listen":
            return "microdramas"
        case "channel":
            return "channels"
        case "followed", "subscriptions":
            return "following"
        case "collection", "library":
            return "collections"
        default:
            return normalized
        }
    }

    static func defaultItem(for id: String) -> PlatformBrowseItem? {
        defaults.first { $0.id == normalizedId(id) }
    }
}

struct PlatformSectionToggle: Decodable {
    let enabled: Bool
    let label: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, visible, page, feed, label, title, name
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let bool = try? single.decode(Bool.self) {
            enabled = bool
            label = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .visible)
            ?? container.decodeIfPresent(Bool.self, forKey: .page)
            ?? container.decodeIfPresent(Bool.self, forKey: .feed)
            ?? true
        label = try container.decodeIfPresent(String.self, forKey: .label)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
    }
}
