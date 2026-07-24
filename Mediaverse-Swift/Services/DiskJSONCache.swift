import Foundation

actor DiskJSONCache {
    static let shared = DiskJSONCache()
    private static let metricsNamespace = "metadata.json"

    private struct DecodedEnvelope<Value: Decodable>: Decodable {
        let cachedAt: Date
        let ttl: TimeInterval
        let value: Value
    }

    private struct EncodedEnvelope<Value: Encodable>: Encodable {
        let cachedAt: Date
        let ttl: TimeInterval
        let value: Value
    }

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
        self.rootURL = caches.appendingPathComponent("MediaverseMetadataCache", isDirectory: true)
    }

    func value<Value: Decodable>(forKey key: String, as type: Value.Type = Value.self) throws -> Value? {
        let fileURL = cacheFileURL(forKey: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(DecodedEnvelope<Value>.self, from: data)
        guard Date().timeIntervalSince(envelope.cachedAt) < envelope.ttl else {
            try? fileManager.removeItem(at: fileURL)
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }
        CacheMetrics.shared.recordHit(Self.metricsNamespace)
        return envelope.value
    }

    func staleValue<Value: Decodable>(forKey key: String, as type: Value.Type = Value.self) throws -> Value? {
        let fileURL = cacheFileURL(forKey: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            CacheMetrics.shared.recordMiss(Self.metricsNamespace)
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        CacheMetrics.shared.recordHit(Self.metricsNamespace)
        return try decoder.decode(DecodedEnvelope<Value>.self, from: data).value
    }

    func store<Value: Encodable>(_ value: Value, forKey key: String, ttl: TimeInterval) throws {
        try ensureRootDirectory()
        let envelope = EncodedEnvelope(cachedAt: Date(), ttl: ttl, value: value)
        let data = try encoder.encode(envelope)
        let fileURL = cacheFileURL(forKey: key)
        try data.write(to: fileURL, options: [.atomic])
        try setFileProtection(at: fileURL)
        CacheMetrics.shared.recordStore(Self.metricsNamespace, bytes: UInt64(data.count))
    }

    func removeValue(forKey key: String) throws {
        let fileURL = cacheFileURL(forKey: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
        CacheMetrics.shared.recordEviction(Self.metricsNamespace)
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
        CacheMetrics.shared.recordEviction(Self.metricsNamespace)
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setFileProtection(at: rootURL)
    }

    private func cacheFileURL(forKey key: String) -> URL {
        rootURL.appendingPathComponent(Self.fileName(forKey: key))
    }

    private static func fileName(forKey key: String) -> String {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)).multipliedReportingOverflow(by: 1_099_511_628_211).partialValue
        }
        return String(hash, radix: 16) + ".json"
    }

    private func setFileProtection(at url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
