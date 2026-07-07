import Foundation

@MainActor
final class StoriesRepository: ObservableObject {
    @Published private(set) var groups: [StoryGroup] = []
    @Published private(set) var isLoading = false
    @Published var lastError: Error?

    private let client: StoriesAPIClient
    private var lastRefreshAt: Date?
    private let cacheTTL: TimeInterval = 30
    private let cacheKey = "westreem.stories.cachedGroups"

    init(client: StoriesAPIClient = .shared) {
        self.client = client
        self.groups = Self.loadCachedGroups(cacheKey: cacheKey)
    }

    func refresh(force: Bool = false) async {
        if !force, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < cacheTTL, !groups.isEmpty {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await client.fetchGroups()
            groups = fetched.filter { !$0.stories.isEmpty }
            saveCachedGroups()
            lastRefreshAt = Date()
            lastError = nil
        } catch {
            if groups.isEmpty {
                groups = Self.loadCachedGroups(cacheKey: cacheKey)
            }
            lastError = error
        }
    }

    func markViewed(storyId: String) async {
        applySeen(storyId: storyId)
        do {
            try await client.markViewed(storyId: storyId)
            saveCachedGroups()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func deleteStory(id: String) async throws {
        try await client.deleteStory(id: id)
        for index in groups.indices {
            groups[index].stories.removeAll { $0.id == id }
            groups[index].hasUnseen = groups[index].stories.contains { !$0.seen }
        }
        groups.removeAll { $0.stories.isEmpty }
        saveCachedGroups()
    }

    private func applySeen(storyId: String) {
        for groupIndex in groups.indices {
            guard let storyIndex = groups[groupIndex].stories.firstIndex(where: { $0.id == storyId }) else { continue }
            groups[groupIndex].stories[storyIndex].seen = true
            groups[groupIndex].hasUnseen = groups[groupIndex].stories.contains { !$0.seen }
            saveCachedGroups()
            return
        }
    }

    private func saveCachedGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private static func loadCachedGroups(cacheKey: String) -> [StoryGroup] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([StoryGroup].self, from: data) else {
            return []
        }
        return decoded.filter { !$0.stories.isEmpty }
    }
}
