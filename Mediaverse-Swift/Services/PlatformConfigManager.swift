import Foundation

@MainActor
final class PlatformConfigManager: ObservableObject {
    @Published private(set) var config: PlatformConfig = .default
    @Published private(set) var isLoaded = false

    var storiesFeedEnabled: Bool {
        config.storiesFeedEnabled
    }

    func refresh() async {
        do {
            config = try await APIClient.shared.fetchPlatformConfig()
        } catch {
            config = .default
        }
        isLoaded = true
    }
}
