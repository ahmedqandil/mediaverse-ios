import Foundation

actor CacheMaintenanceService {
    static let shared = CacheMaintenanceService()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func trimForBackground() async {
        await RemoteImageCache.shared.trimDisk()
        try? await StoryMediaCache.shared.trim()
        try? await StoryExportCache.shared.trim()
    }

    func trimForMemoryPressure() async {
        URLCache.shared.removeAllCachedResponses()
        await MainPageWarmupService.shared.cancelWarmup()
        await RemoteImageCache.shared.clearMemory()
        await RemoteImageCache.shared.trimDisk(maxBytes: 160 * 1024 * 1024)
        try? await StoryMediaCache.shared.trim()
        try? await StoryExportCache.shared.trim()
        trimDirectory(named: "MediaverseStoryOverlayCache", maxBytes: 60 * 1024 * 1024)
    }

    func clearUserScopedCaches() async {
        URLCache.shared.removeAllCachedResponses()
        await MainPageWarmupService.shared.cancelWarmup()
        await MainActor.run { UploadOptionsCache.clear() }
        await RemoteImageCache.shared.removeAll()
        try? await DiskJSONCache.shared.removeAll()
        try? await StoryFeedDiskCache.shared.removeAll()
        try? await StoryMediaCache.shared.removeAll()
        try? await StoryExportCache.shared.removeAll()
        removeDirectory(named: "MediaverseStoryOverlayCache")
        CacheMetrics.shared.reset()
    }

    private func removeDirectory(named name: String) {
        let url = cacheDirectory(named: name)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func trimDirectory(named name: String, maxBytes: UInt64) {
        let url = cacheDirectory(named: name)
        guard fileManager.fileExists(atPath: url.path),
              let files = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let entries = files.compactMap { fileURL -> (url: URL, size: UInt64, modifiedAt: Date)? in
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values?.fileSize else { return nil }
            return (fileURL, UInt64(size), values?.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard totalBytes > maxBytes else { return }

        var evictedCount = 0
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? fileManager.removeItem(at: entry.url)
            evictedCount += 1
            totalBytes = totalBytes > entry.size ? totalBytes - entry.size : 0
            if totalBytes <= maxBytes { break }
        }
        if evictedCount > 0 {
            CacheMetrics.shared.recordEviction("story.overlay", count: evictedCount)
        }
    }

    private func cacheDirectory(named name: String) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent(name, isDirectory: true)
    }
}
