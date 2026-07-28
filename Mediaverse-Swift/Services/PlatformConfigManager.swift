import Foundation

@MainActor
final class PlatformConfigManager: ObservableObject {
    @Published private(set) var config: PlatformConfig = .default
    @Published private(set) var isLoaded = false

    var storiesFeedEnabled: Bool {
        config.storiesFeedEnabled
    }

    var browseSections: [PlatformBrowseItem] {
        config.browseSections
    }

    func browseItem(id: String) -> PlatformBrowseItem {
        let normalizedId = PlatformBrowseItem.normalizedId(id)
        return browseSections.first { $0.id == normalizedId }
            ?? PlatformBrowseItem.defaultItem(for: normalizedId)
            ?? PlatformBrowseItem(id: normalizedId, label: id, enabled: true)
    }

    func browseSectionEnabled(_ id: String) -> Bool {
        browseItem(id: id).enabled
    }

    func isEnabled(_ id: String, aspect: PlatformSectionAspect) -> Bool {
        browseItem(id: id).isEnabled(aspect)
    }

    var hasVisibleEpisodeTypes: Bool {
        ["shows", "movies", "microdramas"].contains {
            isEnabled($0, aspect: .feed) && isEnabled($0, aspect: .page)
        }
    }

    func refresh() async {
        do {
            config = try await APIClient.shared.fetchPlatformConfig()
        } catch {
            if !isLoaded {
                config = .default
            }
        }
        isLoaded = true
    }
}
