import Foundation

actor StoryFeedDiskCache {
    static let shared = StoryFeedDiskCache()

    private static let metricsNamespace = "story.feed"
    private static let cacheVersion = "v2"
    private static let fileName = cacheVersion + "-groups.json"
    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = caches.appendingPathComponent("MediaverseStoryFeedCache", isDirectory: true)
    }

    func store(_ groups: [StoryGroup]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setFileProtection(at: rootURL)
        let data = try encoder.encode(groups)
        try data.write(to: cacheURL, options: [.atomic])
        try setFileProtection(at: cacheURL)
        CacheMetrics.shared.recordStore(Self.metricsNamespace, bytes: UInt64(data.count))
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }

    nonisolated static func loadCachedGroups(fileManager: FileManager = .default) -> [StoryGroup] {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = caches
            .appendingPathComponent("MediaverseStoryFeedCache", isDirectory: true)
            .appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([StoryGroup].self, from: data) else {
            CacheMetrics.shared.recordMiss(metricsNamespace)
            return []
        }
        CacheMetrics.shared.recordHit(metricsNamespace)
        return decoded.filter { !$0.stories.isEmpty }
    }

    private var cacheURL: URL {
        rootURL.appendingPathComponent(Self.fileName)
    }

    private func setFileProtection(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
