import Foundation

enum CacheWarmupPriority: Sendable {
    case immediate
    case high
    case background

    var urlSessionPriority: Float {
        switch self {
        case .immediate: return URLSessionTask.highPriority
        case .high: return URLSessionTask.defaultPriority
        case .background: return URLSessionTask.lowPriority
        }
    }
}

actor StoryMediaCache {
    static let shared = StoryMediaCache()
    private static let metricsNamespace = "story.media"
    private static let cacheVersion = "v2"

    private let fileManager: FileManager
    private let rootURL: URL
    private let maxBytes: UInt64

    init(fileManager: FileManager = .default, maxBytes: UInt64 = 300 * 1024 * 1024) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = caches.appendingPathComponent("MediaverseStoryMediaCache", isDirectory: true)
    }

    func localURL(for remoteURL: URL) throws -> URL? {
        let fileURL = cacheFileURL(for: remoteURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }
        touch(fileURL)
        CacheMetrics.shared.recordHit(Self.metricsNamespace)
        return fileURL
    }

    @discardableResult
    func cachedURL(for remoteURL: URL, priority: CacheWarmupPriority = .high) async throws -> URL {
        let fileURL = cacheFileURL(for: remoteURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            touch(fileURL)
            CacheMetrics.shared.recordHit(Self.metricsNamespace)
            return fileURL
        }
        CacheMetrics.shared.recordMiss(Self.metricsNamespace)

        try ensureRootDirectory()
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .returnCacheDataElseLoad
        let temporaryURL = try await downloadFile(for: request, priority: priority)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
            touch(fileURL)
            return fileURL
        }
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
        try setFileProtection(at: fileURL)
        touch(fileURL)
        let storedBytes = UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        CacheMetrics.shared.recordStore(Self.metricsNamespace, bytes: storedBytes)
        try evictIfNeeded()
        return fileURL
    }

    private func downloadFile(for request: URLRequest, priority: CacheWarmupPriority) async throws -> URL {
        let box = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: request) { temporaryURL, _, error in
                    if let error {
                        CacheMetrics.shared.recordError(Self.metricsNamespace)
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let temporaryURL else {
                        CacheMetrics.shared.recordError(Self.metricsNamespace)
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: temporaryURL)
                }
                task.priority = priority.urlSessionPriority
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
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

    private func cacheFileURL(for remoteURL: URL) -> URL {
        let pathExtension = remoteURL.pathExtension.isEmpty ? "media" : remoteURL.pathExtension
        return rootURL.appendingPathComponent(Self.fileName(forKey: Self.cacheVersion + ":" + remoteURL.absoluteString, extension: pathExtension))
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func evictIfNeeded() throws {
        let files = try cacheFiles()
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        guard totalBytes > maxBytes else { return }

        var remainingBytes = totalBytes
        var evictedCount = 0
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? fileManager.removeItem(at: file.url)
            evictedCount += 1
            remainingBytes = remainingBytes > file.size ? remainingBytes - file.size : 0
            if remainingBytes <= maxBytes { break }
        }
        if evictedCount > 0 {
            CacheMetrics.shared.recordEviction(Self.metricsNamespace, count: evictedCount)
        }
    }

    private func cacheFiles() throws -> [(url: URL, size: UInt64, modifiedAt: Date)] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values?.fileSize else { return nil }
            return (url, UInt64(size), values?.contentModificationDate ?? .distantPast)
        }
    }

    private static func fileName(forKey key: String, extension pathExtension: String) -> String {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)).multipliedReportingOverflow(by: 1_099_511_628_211).partialValue
        }
        return String(hash, radix: 16) + "." + pathExtension
    }

    private func setFileProtection(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}
