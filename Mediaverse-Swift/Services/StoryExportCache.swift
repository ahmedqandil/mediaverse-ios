import CryptoKit
import Foundation

actor StoryExportCache {
    static let shared = StoryExportCache()
    private static let metricsNamespace = "story.export"
    private static let cacheVersion = "v4"

    private struct Entry: Codable {
        let key: String
        let fileName: String
        let mimeType: String
        let mediaType: String
        let duration: Int
        let cachedAt: Date
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxBytes: UInt64
    private let maxEntries: Int

    init(fileManager: FileManager = .default, maxBytes: UInt64 = 500 * 1024 * 1024, maxEntries: Int = 20) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = caches.appendingPathComponent("MediaverseStoryExportCache", isDirectory: true)
    }

    func cachedResult(for key: String) throws -> StoryExportResult? {
        let versionedKey = Self.versionedKey(key)
        let metadataURL = metadataURL(for: versionedKey)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }
        guard let data = try? Data(contentsOf: metadataURL),
              let entry = try? decoder.decode(Entry.self, from: data),
              entry.key == versionedKey,
              !entry.fileName.isEmpty,
              URL(fileURLWithPath: entry.fileName).lastPathComponent == entry.fileName else {
            try? fileManager.removeItem(at: metadataURL)
            CacheMetrics.shared.recordError(Self.metricsNamespace)
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }
        let mediaURL = rootURL.appendingPathComponent(entry.fileName)
        let fileSize = (try? mediaURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileManager.fileExists(atPath: mediaURL.path), fileSize > 0 else {
            try? fileManager.removeItem(at: mediaURL)
            try? fileManager.removeItem(at: metadataURL)
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }
        touch(mediaURL)
        touch(metadataURL)
        CacheMetrics.shared.recordHit(Self.metricsNamespace)
        return StoryExportResult(
            url: mediaURL,
            mimeType: entry.mimeType,
            mediaType: entry.mediaType,
            duration: entry.duration,
            isCacheHit: true
        )
    }

    @discardableResult
    func store(_ result: StoryExportResult, for key: String) throws -> StoryExportResult {
        try ensureRootDirectory()
        let versionedKey = Self.versionedKey(key)
        let fileExtension = result.url.pathExtension.isEmpty ? defaultExtension(for: result.mimeType) : result.url.pathExtension
        let fileName = versionedKey + "." + fileExtension
        let destinationURL = rootURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: result.url, to: destinationURL)
        try setFileProtection(at: destinationURL)
        let entry = Entry(
            key: versionedKey,
            fileName: fileName,
            mimeType: result.mimeType,
            mediaType: result.mediaType,
            duration: result.duration,
            cachedAt: Date()
        )
        let metadataURL = metadataURL(for: versionedKey)
        try encoder.encode(entry).write(to: metadataURL, options: [.atomic])
        try setFileProtection(at: metadataURL)
        touch(destinationURL)
        let storedBytes = UInt64((try? destinationURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        CacheMetrics.shared.recordStore(Self.metricsNamespace, bytes: storedBytes)
        try evictIfNeeded()
        return StoryExportResult(
            url: destinationURL,
            mimeType: result.mimeType,
            mediaType: result.mediaType,
            duration: result.duration,
            isCacheHit: false
        )
    }

    func trim() throws {
        try evictIfNeeded()
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setFileProtection(at: rootURL)
    }

    private func metadataURL(for key: String) -> URL {
        rootURL.appendingPathComponent(key + ".json")
    }

    private func defaultExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        default: return "mp4"
        }
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func evictIfNeeded() throws {
        let entries = try cacheEntries()
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.mediaSize + $1.metadataSize }
        guard totalBytes > maxBytes || entries.count > maxEntries else { return }

        var remainingBytes = totalBytes
        var remainingCount = entries.count
        var evictedCount = 0
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? fileManager.removeItem(at: entry.mediaURL)
            try? fileManager.removeItem(at: entry.metadataURL)
            evictedCount += 1
            remainingBytes = remainingBytes > entry.mediaSize + entry.metadataSize ? remainingBytes - entry.mediaSize - entry.metadataSize : 0
            remainingCount -= 1
            if remainingBytes <= maxBytes && remainingCount <= maxEntries { break }
        }
        if evictedCount > 0 {
            CacheMetrics.shared.recordEviction(Self.metricsNamespace, count: evictedCount)
        }
    }

    private func cacheEntries() throws -> [(mediaURL: URL, metadataURL: URL, mediaSize: UInt64, metadataSize: UInt64, modifiedAt: Date)] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let metadataURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        return metadataURLs.compactMap { metadataURL in
            guard let data = try? Data(contentsOf: metadataURL),
                  let entry = try? decoder.decode(Entry.self, from: data) else { return nil }
            let mediaURL = rootURL.appendingPathComponent(entry.fileName)
            guard fileManager.fileExists(atPath: mediaURL.path) else {
                try? fileManager.removeItem(at: metadataURL)
                return nil
            }
            let metadataValues = try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mediaValues = try? mediaURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = max(metadataValues?.contentModificationDate ?? .distantPast, mediaValues?.contentModificationDate ?? .distantPast)
            return (
                mediaURL,
                metadataURL,
                UInt64(mediaValues?.fileSize ?? 0),
                UInt64(metadataValues?.fileSize ?? 0),
                modifiedAt
            )
        }
    }

    private static func versionedKey(_ key: String) -> String {
        cacheVersion + "-" + key
    }

    private func setFileProtection(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
