import Foundation

struct PlatformConfig: Decodable {
    let sections: PlatformSections

    static let `default` = PlatformConfig(sections: .default)

    var storiesFeedEnabled: Bool {
        sections.stories.feed
    }
}

struct PlatformSections: Decodable {
    let stories: PlatformStorySection

    static let `default` = PlatformSections(stories: .default)

    private enum CodingKeys: String, CodingKey {
        case stories
    }

    init(stories: PlatformStorySection) {
        self.stories = stories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stories = try container.decodeIfPresent(PlatformStorySection.self, forKey: .stories) ?? .default
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
