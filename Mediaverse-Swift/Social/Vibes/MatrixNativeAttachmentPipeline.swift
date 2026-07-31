@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum MatrixNativeAttachmentQuality: String, CaseIterable, Codable, Sendable {
    case dataSaver
    case standard
    case original

    var title: String {
        switch self {
        case .dataSaver: "Data Saver"
        case .standard: "Standard"
        case .original: "Original"
        }
    }
}

enum MatrixNativeUploadStage: String, Codable, Sendable {
    case queued
    case preparing
    case compressing
    case uploading
    case sending
    case delivered
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .compressing: "Compressing"
        case .uploading: "Uploading"
        case .sending: "Sending"
        case .delivered: "Delivered"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var isTerminal: Bool { self == .delivered || self == .failed || self == .cancelled }
}

struct MatrixNativeQueuedAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID
    let accountID: String
    let roomID: String
    let transactionID: String
    let kind: MatrixNativeAttachmentKind
    let originalFilename: String
    let originalMimeType: String
    let quality: MatrixNativeAttachmentQuality
    let stagedFilename: String
    var preparedFilename: String?
    var posterFilename: String?
    var caption: String?
    var stage: MatrixNativeUploadStage
    /// Present only when progress comes from an authoritative byte source.
    var progress: Double?
    var transferredBytes: Int64?
    var totalBytes: Int64
    var width: UInt64?
    var height: UInt64?
    var duration: TimeInterval?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    var optimisticPreviewFilename: String { posterFilename ?? preparedFilename ?? stagedFilename }
}

struct MatrixNativeUploadSummary: Equatable, Sendable {
    let activeCount: Int
    let completedCount: Int
    let failedCount: Int
    /// Nil means at least one active transfer is indeterminate.
    let progress: Double?
    let transferredBytes: Int64?
    let totalBytes: Int64
}

struct MatrixNativePreparedAttachment: Sendable {
    let upload: MatrixNativeUpload
    let posterData: Data?
}

/// A navigation-safe, restart-safe queue. The queue owns protected staging files;
/// room views only observe state and provide the canonical Matrix send operation.
/// Matrix transaction IDs are persisted to make retries idempotent at the SDK boundary.
@MainActor
final class MatrixNativeAttachmentUploadQueue: ObservableObject {
    typealias MatrixSender = @Sendable (MatrixNativePreparedAttachment, String?, String) async throws -> Void
    typealias MatrixBatchSender = @Sendable ([MatrixNativeUpload], String?, String) async throws -> Void

    static let shared = MatrixNativeAttachmentUploadQueue()

    @Published private(set) var items: [MatrixNativeQueuedAttachment] = []
    @Published private(set) var summary = MatrixNativeUploadSummary(
        activeCount: 0, completedCount: 0, failedCount: 0,
        progress: nil, transferredBytes: nil, totalBytes: 0
    )

    private let fileManager: FileManager
    private let rootURL: URL
    private let manifestURL: URL
    private var work: [UUID: Task<Void, Never>] = [:]

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let base = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = base.appendingPathComponent("MatrixAttachmentQueue", isDirectory: true)
        self.manifestURL = self.rootURL.appendingPathComponent("manifest.json")
        try? Self.createProtectedDirectory(self.rootURL, fileManager: fileManager)
        self.items = Self.restoreManifest(at: self.manifestURL)
            .map { item in
                var restored = item
                if !restored.stage.isTerminal {
                    restored.stage = .queued
                    restored.progress = nil
                    restored.errorMessage = "Ready to resume"
                }
                return restored
            }
        recalculateSummary()
    }

    @discardableResult
    func enqueue(
        data: Data,
        accountID: String,
        roomID: String,
        kind: MatrixNativeAttachmentKind,
        filename: String,
        mimeType: String,
        quality: MatrixNativeAttachmentQuality = .standard,
        caption: String? = nil,
        sender: @escaping MatrixSender
    ) throws -> UUID {
        try enqueueBatch(
            uploads: [MatrixNativeUpload(kind: kind, data: data, filename: filename, mimeType: mimeType)],
            accountID: accountID,
            roomID: roomID,
            quality: quality,
            caption: caption
        ) { uploads, caption, transactionID in
            guard let upload = uploads.first else { throw MatrixNativeMediaError.invalidAttachment }
            try await sender(MatrixNativePreparedAttachment(upload: upload, posterData: nil), caption, transactionID)
        }
    }

    /// Stages a selection as one logical Matrix gallery. Selection order,
    /// caption and transaction identity remain stable across preparation and retry.
    @discardableResult
    func enqueueBatch(
        uploads: [MatrixNativeUpload],
        accountID: String,
        roomID: String,
        quality: MatrixNativeAttachmentQuality = .standard,
        caption: String? = nil,
        sender: @escaping MatrixBatchSender
    ) throws -> UUID {
        guard !uploads.isEmpty else { throw MatrixNativeMediaError.invalidAttachment }
        let batchID = UUID()
        let transactionID = "westreem-media-batch-\(batchID.uuidString.lowercased())"
        var staged: [MatrixNativeQueuedAttachment] = []
        do {
            for upload in uploads {
                let id = upload.id
                let safeExtension = Self.safeExtension(filename: upload.filename, mimeType: upload.mimeType)
                let stagedFilename = "\(id.uuidString).source.\(safeExtension)"
                try upload.data.write(
                    to: rootURL.appendingPathComponent(stagedFilename),
                    options: [.atomic, .completeFileProtection]
                )
                staged.append(MatrixNativeQueuedAttachment(
                    id: id,
                    batchID: batchID,
                    accountID: accountID,
                    roomID: roomID,
                    transactionID: transactionID,
                    kind: upload.kind,
                    originalFilename: String(upload.filename.prefix(255)),
                    originalMimeType: upload.mimeType,
                    quality: quality,
                    stagedFilename: stagedFilename,
                    preparedFilename: nil,
                    posterFilename: nil,
                    caption: caption,
                    stage: .queued,
                    progress: nil,
                    transferredBytes: nil,
                    totalBytes: Int64(upload.data.count),
                    width: upload.width,
                    height: upload.height,
                    duration: upload.duration,
                    errorMessage: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                ))
            }
        } catch {
            for item in staged { try? fileManager.removeItem(at: rootURL.appendingPathComponent(item.stagedFilename)) }
            throw error
        }
        items.append(contentsOf: staged)
        persist()
        recalculateSummary()
        start(batchID: batchID, sender: sender)
        return batchID
    }

    private func legacyItem(
        data: Data,
        accountID: String,
        roomID: String,
        kind: MatrixNativeAttachmentKind,
        filename: String,
        mimeType: String,
        quality: MatrixNativeAttachmentQuality,
        caption: String?
    ) throws -> UUID {
        let id = UUID()
        let batchID = UUID()
        let safeExtension = Self.safeExtension(filename: filename, mimeType: mimeType)
        let stagedFilename = "\(id.uuidString).source.\(safeExtension)"
        try data.write(to: rootURL.appendingPathComponent(stagedFilename), options: [.atomic, .completeFileProtection])
        let item = MatrixNativeQueuedAttachment(
            id: id,
            batchID: batchID,
            accountID: accountID,
            roomID: roomID,
            transactionID: "westreem-media-\(id.uuidString.lowercased())",
            kind: kind,
            originalFilename: String(filename.prefix(255)),
            originalMimeType: MatrixNativeMediaPolicy.baseMimeType(mimeType) ?? mimeType,
            quality: quality,
            stagedFilename: stagedFilename,
            preparedFilename: nil,
            posterFilename: nil,
            caption: caption,
            stage: .queued,
            progress: nil,
            transferredBytes: nil,
            totalBytes: Int64(data.count),
            width: nil,
            height: nil,
            duration: nil,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        items.append(item)
        persist()
        // Kept only for decoding/source compatibility; new work uses enqueueBatch.
        return id
    }

    func resumeQueued(using sender: @escaping MatrixSender) {
        let batchSender: MatrixBatchSender = { uploads, caption, transactionID in
            guard let upload = uploads.first else { throw MatrixNativeMediaError.invalidAttachment }
            try await sender(MatrixNativePreparedAttachment(upload: upload, posterData: nil), caption, transactionID)
        }
        for batchID in Set(items.filter { $0.stage == .queued || $0.stage == .failed }.map(\.batchID)) {
            start(batchID: batchID, sender: batchSender)
        }
    }

    func retry(id: UUID, using sender: @escaping MatrixSender) {
        guard let batchID = items.first(where: { $0.id == id })?.batchID else { return }
        let batchSender: MatrixBatchSender = { uploads, caption, transactionID in
            guard let upload = uploads.first else { throw MatrixNativeMediaError.invalidAttachment }
            try await sender(MatrixNativePreparedAttachment(upload: upload, posterData: nil), caption, transactionID)
        }
        retry(batchID: batchID, using: batchSender)
    }

    func retry(batchID: UUID, using sender: @escaping MatrixBatchSender) {
        guard mutateBatch(batchID, { item in
            item.stage = .queued
            item.progress = nil
            item.transferredBytes = nil
            item.errorMessage = nil
            item.updatedAt = Date()
        }) else { return }
        start(batchID: batchID, sender: sender)
    }

    func cancel(id: UUID) {
        guard let batchID = items.first(where: { $0.id == id })?.batchID else { return }
        work[batchID]?.cancel()
        work[batchID] = nil
        _ = mutateBatch(batchID) { item in
            item.stage = .cancelled
            item.errorMessage = nil
            item.updatedAt = Date()
        }
    }

    func remove(id: UUID) {
        work[id]?.cancel()
        guard let item = items.first(where: { $0.id == id }) else { return }
        for filename in [item.stagedFilename, item.preparedFilename, item.posterFilename].compactMap({ $0 }) {
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(filename))
        }
        items.removeAll { $0.id == id }
        persist()
        recalculateSummary()
    }

    func previewURL(for id: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return rootURL.appendingPathComponent(item.optimisticPreviewFilename)
    }

    private func start(batchID: UUID, sender: @escaping MatrixBatchSender) {
        guard work[batchID] == nil else { return }
        work[batchID] = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                // `items` retains picker order; never sort gallery selections by timestamps.
                let batch = self.items.filter { $0.batchID == batchID }
                guard let first = batch.first else { return }
                var preparedUploads: [MatrixNativeUpload] = []
                for item in batch {
                    self.setStage(item.id, .preparing)
                    let sourceURL = self.rootURL.appendingPathComponent(item.stagedFilename)
                    self.setStage(item.id, .compressing)
                    let itemID = item.id
                    let destinationRoot = self.rootURL
                    let persisted = try await Task.detached(priority: .userInitiated) {
                        let prepared = try await MatrixNativeAttachmentPreparer.prepare(item: item, sourceURL: sourceURL)
                        let preparedFilename = "\(itemID.uuidString).prepared.\(Self.safeExtension(filename: prepared.upload.filename, mimeType: prepared.upload.mimeType))"
                        try prepared.upload.data.write(
                            to: destinationRoot.appendingPathComponent(preparedFilename),
                            options: [.atomic, .completeFileProtection]
                        )
                        var posterFilename: String?
                        if let poster = prepared.posterData {
                            let name = "\(itemID.uuidString).poster.jpg"
                            try poster.write(
                                to: destinationRoot.appendingPathComponent(name),
                                options: [.atomic, .completeFileProtection]
                            )
                            posterFilename = name
                        }
                        return (prepared, preparedFilename, posterFilename)
                    }.value
                    try Task.checkCancellation()
                    let prepared = persisted.0
                    let preparedFilename = persisted.1
                    let posterFilename = persisted.2
                    _ = self.mutate(item.id) { value in
                        value.preparedFilename = preparedFilename
                        value.posterFilename = posterFilename
                        value.width = prepared.upload.width
                        value.height = prepared.upload.height
                        value.duration = prepared.upload.duration
                        value.totalBytes = Int64(prepared.upload.data.count)
                        value.progress = nil
                        value.transferredBytes = nil
                        value.updatedAt = Date()
                    }
                    preparedUploads.append(prepared.upload)
                }
                _ = self.mutateBatch(batchID) { value in
                    value.stage = .uploading
                    value.progress = nil
                    value.transferredBytes = nil
                    value.updatedAt = Date()
                }
                // Exactly one SDK send preserves Matrix gallery semantics.
                try await sender(preparedUploads, first.caption, first.transactionID)
                try Task.checkCancellation()
                _ = self.mutateBatch(batchID) { value in value.stage = .sending; value.progress = nil; value.transferredBytes = nil }
                _ = self.mutateBatch(batchID) { value in value.stage = .delivered; value.progress = 1; value.transferredBytes = value.totalBytes }
            } catch is CancellationError {
                _ = self.mutateBatch(batchID) { value in value.stage = .cancelled; value.progress = nil; value.transferredBytes = nil }
            } catch {
                _ = self.mutateBatch(batchID) { item in
                    item.stage = .failed
                    item.errorMessage = error.localizedDescription
                    item.updatedAt = Date()
                }
            }
            self.work[batchID] = nil
        }
    }

    private func setStage(_ id: UUID, _ stage: MatrixNativeUploadStage) {
        _ = mutate(id) { item in
            item.stage = stage
            item.progress = nil
            item.transferredBytes = nil
            item.updatedAt = Date()
        }
    }

    @discardableResult
    private func mutate(_ id: UUID, _ change: (inout MatrixNativeQueuedAttachment) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        change(&items[index])
        persist()
        recalculateSummary()
        return true
    }

    @discardableResult
    private func mutateBatch(_ batchID: UUID, _ change: (inout MatrixNativeQueuedAttachment) -> Void) -> Bool {
        let indices = items.indices.filter { items[$0].batchID == batchID }
        guard !indices.isEmpty else { return false }
        for index in indices { change(&items[index]) }
        persist()
        recalculateSummary()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifestURL, options: [.atomic, .completeFileProtection])
    }

    private func recalculateSummary() {
        let active = items.filter { !$0.stage.isTerminal }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let isMeasured = active.allSatisfy { $0.progress != nil && $0.transferredBytes != nil }
        let transferred = isMeasured ? active.reduce(Int64(0)) { $0 + ($1.transferredBytes ?? 0) } : nil
        summary = MatrixNativeUploadSummary(
            activeCount: active.count,
            completedCount: items.filter { $0.stage == .delivered }.count,
            failedCount: items.filter { $0.stage == .failed }.count,
            progress: isMeasured && total > 0 ? Double(transferred ?? 0) / Double(total) : nil,
            transferredBytes: transferred,
            totalBytes: total
        )
    }

    private static func restoreManifest(at url: URL) -> [MatrixNativeQueuedAttachment] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([MatrixNativeQueuedAttachment].self, from: data) else { return [] }
        return items
    }

    private static func createProtectedDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    nonisolated private static func safeExtension(filename: String, mimeType: String) -> String {
        let candidate = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if !candidate.isEmpty, candidate.count <= 8, candidate.allSatisfy({ $0.isLetter || $0.isNumber }) { return candidate }
        return UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "bin"
    }
}

enum MatrixNativeAttachmentPreparer {
    static func prepare(item: MatrixNativeQueuedAttachment, sourceURL: URL) async throws -> MatrixNativePreparedAttachment {
        switch item.kind {
        case .image, .sticker:
            return try prepareImage(item: item, sourceURL: sourceURL)
        case .video:
            return try await prepareVideo(item: item, sourceURL: sourceURL)
        default:
            let data = try Data(contentsOf: sourceURL)
            return MatrixNativePreparedAttachment(
                upload: MatrixNativeUpload(
                    id: item.id, kind: item.kind, data: data,
                    filename: item.originalFilename, mimeType: item.originalMimeType
                ),
                posterData: nil
            )
        }
    }

    private static func prepareImage(item: MatrixNativeQueuedAttachment, sourceURL: URL) throws -> MatrixNativePreparedAttachment {
        let sourceData = try Data(contentsOf: sourceURL)
        guard item.quality != .original else {
            let image = UIImage(data: sourceData)
            return MatrixNativePreparedAttachment(
                upload: MatrixNativeUpload(
                    id: item.id, kind: item.kind, data: sourceData,
                    filename: item.originalFilename, mimeType: item.originalMimeType,
                    width: image.map { UInt64($0.size.width * $0.scale) },
                    height: image.map { UInt64($0.size.height * $0.scale) }
                ), posterData: thumbnail(from: sourceData)
            )
        }
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        let maxDimension = item.quality == .dataSaver ? 1600 : 2560
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        // Re-encoding from pixels deliberately strips GPS and unnecessary EXIF metadata.
        let image = UIImage(cgImage: cgImage)
        let quality: CGFloat = item.quality == .dataSaver ? 0.72 : 0.84
        guard let encoded = image.jpegData(compressionQuality: quality) else { throw MatrixNativeMediaError.invalidAttachment }
        let keepOriginal = encoded.count >= Int(Double(sourceData.count) * 0.85)
        let data = keepOriginal ? sourceData : encoded
        let mime = keepOriginal ? item.originalMimeType : "image/jpeg"
        let filename = keepOriginal ? item.originalFilename : "\(item.id.uuidString).jpg"
        return MatrixNativePreparedAttachment(
            upload: MatrixNativeUpload(
                id: item.id, kind: item.kind, data: data, filename: filename, mimeType: mime,
                width: UInt64(cgImage.width), height: UInt64(cgImage.height)
            ),
            posterData: thumbnail(from: data)
        )
    }

    private static func prepareVideo(item: MatrixNativeQueuedAttachment, sourceURL: URL) async throws -> MatrixNativePreparedAttachment {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard MatrixNativeMediaSafetyContract.acceptsDuration(duration, for: .video) else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        let poster = try? videoPoster(asset: asset)
        guard item.quality != .original else {
            let data = try Data(contentsOf: sourceURL)
            return MatrixNativePreparedAttachment(
                upload: MatrixNativeUpload(
                    id: item.id, kind: .video, data: data,
                    filename: item.originalFilename, mimeType: item.originalMimeType,
                    duration: duration
                ), posterData: poster
            )
        }
        let preset = item.quality == .dataSaver
            ? AVAssetExportPreset1280x720
            : AVAssetExportPreset1920x1080
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MatrixNativeMediaError.unsupportedAttachment
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("westreem-\(item.id.uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: exporter.error ?? MatrixNativeMediaError.invalidAttachment)
                    }
                }
            }
        } onCancel: {
            exporter.cancelExport()
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let original = try Data(contentsOf: sourceURL)
        let encoded = try Data(contentsOf: outputURL)
        let keepOriginal = encoded.count >= Int(Double(original.count) * 0.85)
        return MatrixNativePreparedAttachment(
            upload: MatrixNativeUpload(
                id: item.id, kind: .video,
                data: keepOriginal ? original : encoded,
                filename: keepOriginal ? item.originalFilename : "\(item.id.uuidString).mp4",
                mimeType: keepOriginal ? item.originalMimeType : "video/mp4",
                duration: duration
            ), posterData: poster
        )
    }

    private static func videoPoster(asset: AVAsset) throws -> Data {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let image = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.78) else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        return data
    }

    private static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.78)
    }
}

/// Account-scoped two-tier thumbnail cache. Cache keys include the Matrix
/// account, room, MXC/encrypted source identity, requested size, and transform version.
actor MatrixNativeThumbnailCache {
    static let shared = MatrixNativeThumbnailCache()

    private let memory: NSCache<NSString, NSData>
    private let fileManager: FileManager
    private let rootURL: URL
    private let byteLimit: Int64 = 200 * 1_024 * 1_024

    init(rootURL: URL? = nil) {
        let manager = FileManager.default
        let cache = NSCache<NSString, NSData>()
        let base = rootURL ?? manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.fileManager = manager
        self.memory = cache
        self.rootURL = base.appendingPathComponent("MatrixThumbnails", isDirectory: true)
        cache.totalCostLimit = 48 * 1_024 * 1_024
        try? manager.createDirectory(
            at: self.rootURL, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    func data(accountID: String, roomID: String, sourceIdentity: String, width: Int, height: Int) -> Data? {
        let key = cacheKey(accountID: accountID, roomID: roomID, sourceIdentity: sourceIdentity, width: width, height: height)
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }
        let url = rootURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func insert(_ data: Data, accountID: String, roomID: String, sourceIdentity: String, width: Int, height: Int) {
        let key = cacheKey(accountID: accountID, roomID: roomID, sourceIdentity: sourceIdentity, width: width, height: height)
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try? data.write(to: rootURL.appendingPathComponent(key), options: [.atomic, .completeFileProtection])
        evictIfNeeded()
    }

    func clear(accountID: String) {
        memory.removeAllObjects()
        let prefix = Self.digest(accountID).prefix(12)
        guard let files = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? fileManager.removeItem(at: file) }
    }

    private func cacheKey(accountID: String, roomID: String, sourceIdentity: String, width: Int, height: Int) -> String {
        "\(Self.digest(accountID).prefix(12))-\(Self.digest("\(roomID)|\(sourceIdentity)|\(width)x\(height)|v1"))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func evictIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > byteLimit {
            try? fileManager.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

/// Keeps only a small visible-window halo warm and cancels work during fast scrolling.
actor MatrixNativeThumbnailPrefetcher {
    typealias Loader = @Sendable () async throws -> Data
    private var tasks: [String: Task<Void, Never>] = [:]
    private let cache: MatrixNativeThumbnailCache

    init(cache: MatrixNativeThumbnailCache = .shared) { self.cache = cache }

    func prefetch(
        accountID: String,
        roomID: String,
        sourceIdentity: String,
        width: Int,
        height: Int,
        loader: @escaping Loader
    ) {
        guard tasks[sourceIdentity] == nil else { return }
        tasks[sourceIdentity] = Task(priority: .utility) { [cache] in
            if await cache.data(
                accountID: accountID, roomID: roomID, sourceIdentity: sourceIdentity,
                width: width, height: height
            ) == nil, let data = try? await loader() {
                await cache.insert(
                    data, accountID: accountID, roomID: roomID, sourceIdentity: sourceIdentity,
                    width: width, height: height
                )
            }
        }
    }

    func retain(visibleSourceIdentities: Set<String>, haloSourceIdentities: Set<String>) {
        let retained = visibleSourceIdentities.union(haloSourceIdentities)
        for (identity, task) in tasks where !retained.contains(identity) {
            task.cancel()
            tasks[identity] = nil
        }
    }
}
