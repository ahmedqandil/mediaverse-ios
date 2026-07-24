import SwiftUI
import UIKit
import ImageIO

actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private struct InFlightRequest {
        let id: UUID
        let task: Task<UIImage, Error>
    }

    private final class BoxedImage: NSObject {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    private let memoryCache = NSCache<NSString, BoxedImage>()
    private let fileManager: FileManager
    private let rootURL: URL
    private var inFlight: [String: InFlightRequest] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = caches.appendingPathComponent("MediaverseImageCache", isDirectory: true)
        memoryCache.countLimit = 220
        memoryCache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(for url: URL, targetPixelSize: CGSize? = nil) async throws -> UIImage {
        let memoryKey = cacheKey(for: url, targetPixelSize: targetPixelSize)
        let diskKey = url.absoluteString
        if let image = memoryCache.object(forKey: memoryKey as NSString)?.image {
            CacheMetrics.shared.recordHit("image.memory")
            return image
        }
        if let request = inFlight[memoryKey] {
            CacheMetrics.shared.recordHit("image.inflight")
            return try await request.task.value
        }

        let requestID = UUID()
        let task = Task<UIImage, Error>(priority: .utility) {
            if let image = try? await diskImage(forKey: diskKey, targetPixelSize: targetPixelSize) {
                CacheMetrics.shared.recordHit("image.disk")
                return image
            }

            CacheMetrics.shared.recordMiss("image")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            let image = Self.decodeImage(data: data, targetPixelSize: targetPixelSize)
                ?? UIImage(data: data)
                ?? UIImage()
            try? await store(data, forKey: diskKey)
            return image
        }

        inFlight[memoryKey] = InFlightRequest(id: requestID, task: task)
        do {
            let image = try await task.value
            clearInFlightRequest(for: memoryKey, matching: requestID)
            storeInMemory(image, key: memoryKey)
            return image
        } catch {
            clearInFlightRequest(for: memoryKey, matching: requestID)
            throw error
        }
    }

    func prefetch(urls: [URL], targetPixelSize: CGSize? = nil, limit: Int = 12, concurrency: Int = 4) async {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            if !result.contains(url) {
                result.append(url)
            }
        }
        let selectedURLs = Array(uniqueURLs.prefix(limit))
        guard !selectedURLs.isEmpty else { return }

        let batchSize = max(1, concurrency)
        for startIndex in stride(from: 0, to: selectedURLs.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, selectedURLs.count)
            let batch = selectedURLs[startIndex..<endIndex]
            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask(priority: .utility) { [targetPixelSize] in
                        _ = try? await self.image(for: url, targetPixelSize: targetPixelSize)
                    }
                }
            }
        }
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    func trimDisk(maxBytes: UInt64 = 240 * 1024 * 1024) {
        guard fileManager.fileExists(atPath: rootURL.path),
              let files = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let entries = files.compactMap { url -> (url: URL, size: UInt64, modifiedAt: Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let size = values?.fileSize else { return nil }
            return (url, UInt64(size), values?.contentModificationDate ?? .distantPast)
        }
        var totalBytes = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard totalBytes > maxBytes else { return }

        var evicted = 0
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            try? fileManager.removeItem(at: entry.url)
            totalBytes = totalBytes > entry.size ? totalBytes - entry.size : 0
            evicted += 1
            if totalBytes <= maxBytes { break }
        }
        if evicted > 0 {
            CacheMetrics.shared.recordEviction("image.disk", count: evicted)
        }
    }

    func removeAll() {
        memoryCache.removeAllObjects()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        try? fileManager.removeItem(at: rootURL)
        CacheMetrics.shared.recordEviction("image.disk")
    }

    private func diskImage(forKey key: String, targetPixelSize: CGSize?) async throws -> UIImage? {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return Self.decodeImage(data: data, targetPixelSize: targetPixelSize) ?? UIImage(data: data)
    }

    private func store(_ data: Data, forKey key: String) async throws {
        try ensureRootDirectory()
        let url = fileURL(forKey: key)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        CacheMetrics.shared.recordStore("image.disk", bytes: UInt64(data.count))
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        memoryCache.setObject(BoxedImage(image), forKey: key as NSString, cost: pixels * 4)
        CacheMetrics.shared.recordStore("image.memory", bytes: UInt64(max(pixels * 4, 0)))
    }

    private func clearInFlightRequest(for key: String, matching requestID: UUID) {
        guard inFlight[key]?.id == requestID else { return }
        inFlight[key] = nil
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: rootURL.path
        )
    }

    private func fileURL(forKey key: String) -> URL {
        rootURL.appendingPathComponent(Self.fileName(forKey: key))
    }

    private func cacheKey(for url: URL, targetPixelSize: CGSize?) -> String {
        guard let size = targetPixelSize else { return url.absoluteString }
        return "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))"
    }

    private static func fileName(forKey key: String) -> String {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)).multipliedReportingOverflow(by: 1_099_511_628_211).partialValue
        }
        return String(hash, radix: 16) + ".img"
    }

    private static func decodeImage(data: Data, targetPixelSize: CGSize?) -> UIImage? {
        guard let targetPixelSize,
              targetPixelSize.width > 0,
              targetPixelSize.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let maxDimension = max(targetPixelSize.width, targetPixelSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize? = nil
    var loadDelayNanoseconds: UInt64 = 80_000_000
    var fadeIn: Bool = true
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var didRevealImage = false

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
                    .opacity(fadeIn && !didRevealImage ? 0 : 1)
                    .onAppear {
                        guard fadeIn else {
                            didRevealImage = true
                            return
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            didRevealImage = true
                        }
                    }
            } else {
                placeholder()
            }
        }
        .onAppear {
            isVisible = true
            scheduleLoad()
        }
        .onDisappear {
            isVisible = false
            cancelLoad()
        }
        .onChange(of: url) { _, _ in
            image = nil
            didRevealImage = false
            scheduleLoad()
        }
    }

    @MainActor
    private func scheduleLoad() {
        cancelLoad()
        guard isVisible, url != nil else { return }
        loadTask = Task(priority: .utility) { @MainActor in
            try? await Task.sleep(nanoseconds: loadDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @MainActor
    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    @MainActor
    private func load() async {
        guard let url else { return }
        let pixelSize = targetSize.map { CGSize(width: $0.width * displayScale, height: $0.height * displayScale) }
        do {
            let loaded = try await RemoteImageCache.shared.image(for: url, targetPixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
            loadTask = nil
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            loadTask = nil
        }
    }
}
