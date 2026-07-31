import CryptoKit
import Foundation

/// Thin on-disk LRU wrapper for Matrix media/avatar payloads. We already
/// rely on the Rust SDK's SQLite media cache for encrypted decrypts, but the
/// SDK re-decrypts on every load and it doesn't share bytes across app
/// launches for avatars fetched via `getMediaThumbnail`. This adds a
/// short-lived byte cache on top of successful loads so scrolling a Wave
/// timeline doesn't re-hit the Rust SDK for every visible frame.
///
/// - Storage: `FileManager.default.temporaryDirectory /
///   matrix-media-cache/{sha256Prefix}/{sha256}`.
/// - Eviction: LRU by file `contentModificationDate`. Keep at most
///   `maxEntries` files (default 200). Total-size cap is best effort — if
///   the temporary directory is trimmed by iOS at any point, the cache
///   simply misses and falls through to the SDK.
/// - Thread-safety: file I/O is dispatched on a private serial queue so
///   concurrent reads never race a writer that's rewriting the mtime.
final class MatrixNativeMediaCache: @unchecked Sendable {
    static let shared = MatrixNativeMediaCache()

    private let root: URL
    private let queue = DispatchQueue(label: "com.westreem.matrix.media-cache", qos: .utility)
    private let maxEntries: Int
    private let byteBudget: Int

    init(maxEntries: Int = 200, byteBudgetBytes: Int = 128 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.byteBudget = byteBudgetBytes
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrix-media-cache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true
        )
    }

    // MARK: - API

    /// Cache key for a Matrix media descriptor. Combining the JSON source
    /// with the room ID prevents cross-room content-address collisions on
    /// SDK builds that reuse mxc:// URLs across rooms.
    static func key(roomID: String, sourceJSON: String) -> String {
        Self.hash("m:\(roomID)|\(sourceJSON)")
    }

    /// Cache key for an avatar mxc:// URL. Avatars are room-independent.
    static func avatarKey(mxcURL: String) -> String {
        Self.hash("a:\(mxcURL)")
    }

    /// Synchronous read (fast). Returns `nil` on any miss or I/O error.
    /// Bumps the file's `contentModificationDate` so the LRU pass keeps
    /// hot entries.
    func read(key: String) -> Data? {
        let url = fileURL(for: key)
        var data: Data?
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            data = try? Data(contentsOf: url)
            // Touch mtime for LRU. Best effort — ignore errors.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
        }
        return data
    }

    /// Asynchronous write. Eviction runs after every N writes to keep the
    /// cache within `maxEntries` / `byteBudget`.
    func write(key: String, data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let url = self.fileURL(for: key)
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
            self.evictIfNeeded()
        }
    }

    /// Drop everything. Only used by explicit user actions or tests.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.root)
            try? FileManager.default.createDirectory(
                at: self.root,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Internals

    private func fileURL(for key: String) -> URL {
        let prefix = String(key.prefix(2))
        return root.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key)
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func evictIfNeeded() {
        // Must be on `queue`.
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else {
            return
        }
        struct Entry {
            let url: URL
            let mtime: Date
            let size: Int
        }
        var entries: [Entry] = []
        entries.reserveCapacity(files.count)
        var totalBytes = 0
        for path in files {
            let url = root.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date ?? Date.distantPast
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            totalBytes += size
            entries.append(Entry(url: url, mtime: mtime, size: size))
        }

        guard entries.count > maxEntries || totalBytes > byteBudget else { return }

        // Oldest first.
        entries.sort { $0.mtime < $1.mtime }
        var runningCount = entries.count
        var runningBytes = totalBytes
        for entry in entries {
            if runningCount <= maxEntries && runningBytes <= byteBudget { break }
            try? FileManager.default.removeItem(at: entry.url)
            runningCount -= 1
            runningBytes -= entry.size
        }
    }
}
