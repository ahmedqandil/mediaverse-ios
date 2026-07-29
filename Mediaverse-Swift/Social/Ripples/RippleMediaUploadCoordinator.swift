import Foundation

enum RippleMediaUploadState: String, Codable, Sendable {
    case preparing
    case queued
    case uploading
    case processing
    case ready
    case failed
}

struct RippleMediaUploadJob: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let vibeSlug: String
    let waveId: String?
    let kind: ConversationalMediaKind
    let localFilePath: String
    let mimeType: String
    let durationMilliseconds: Int?
    var state: RippleMediaUploadState
    var progress: Double
    var mediaId: String?
    var objectKey: String?
    var media: ConversationalMedia?
    var failureMessage: String?

    var createAttachment: RippleCreateAttachment? {
        guard state == .ready, let mediaId else { return nil }
        switch kind {
        case .voice: return .voice(mediaId: mediaId)
        case .video: return .videoMessage(mediaId: mediaId)
        }
    }
}

private enum RippleMediaUploadError: LocalizedError {
    case invalidUploadURL
    case invalidResponse
    case missingFile

    var errorDescription: String? {
        switch self {
        case .invalidUploadURL: "The media upload destination is invalid."
        case .invalidResponse: "The media upload could not be completed."
        case .missingFile: "The media file is no longer available."
        }
    }
}

/// Background URLSession boundary kept independent from the Ripple composer so
/// recording state, upload state and API state cannot become one fragile view.
private final class RippleBackgroundUploadDriver: NSObject, URLSessionTaskDelegate,
    URLSessionDataDelegate, @unchecked Sendable {
    static let shared = RippleBackgroundUploadDriver()

    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
        let progress: @Sendable (Double) -> Void
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.westreem.app.ripple-media-upload"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func upload(
        preparation: ConversationalMediaUploadPreparation,
        fileURL: URL,
        mimeType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RippleMediaUploadError.missingFile
        }
        guard let uploadURL = URL(string: preparation.uploadURL) else {
            throw RippleMediaUploadError.invalidUploadURL
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = preparation.method
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (field, value) in preparation.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            pending[task.taskIdentifier] = Pending(
                continuation: continuation,
                progress: progress
            )
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let callback = pending[task.taskIdentifier]?.progress
        lock.unlock()
        callback?(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let operation = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let operation else { return }
        if let error {
            operation.continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) {
            operation.continuation.resume()
        } else {
            operation.continuation.resume(throwing: RippleMediaUploadError.invalidResponse)
        }
    }
}

@MainActor
final class RippleMediaUploadCoordinator: ObservableObject {
    static let shared = RippleMediaUploadCoordinator()

    @Published private(set) var jobs: [RippleMediaUploadJob]

    private let defaultsKey = "social.ripple-media.upload-jobs.v1"
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode([RippleMediaUploadJob].self, from: data) {
            jobs = decoded
        } else {
            jobs = []
        }
        // A process termination can interrupt preparation/finalization. Retain
        // the file and expose a retry instead of pretending the Ripple was sent.
        jobs = jobs.map { job in
            var restored = job
            if [.preparing, .uploading, .processing].contains(restored.state) {
                restored.state = .queued
                restored.failureMessage = nil
            }
            return restored
        }
        persist()
    }

    func enqueue(
        sourceURL: URL,
        vibeSlug: String,
        waveId: String?,
        kind: ConversationalMediaKind,
        mimeType: String,
        durationMilliseconds: Int?
    ) throws -> UUID {
        let fileURL = try persistentFileURL(sourceURL: sourceURL, kind: kind)
        let id = UUID()
        jobs.append(
            RippleMediaUploadJob(
                id: id,
                vibeSlug: vibeSlug,
                waveId: waveId,
                kind: kind,
                localFilePath: fileURL.path,
                mimeType: mimeType,
                durationMilliseconds: durationMilliseconds,
                state: .queued,
                progress: 0,
                mediaId: nil,
                objectKey: nil,
                media: nil,
                failureMessage: nil
            )
        )
        persist()
        Task { await start(id: id) }
        return id
    }

    func retry(id: UUID) {
        update(id: id) {
            $0.state = .queued
            $0.progress = 0
            $0.failureMessage = nil
        }
        Task { await start(id: id) }
    }

    func remove(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(atPath: job.localFilePath)
        jobs.removeAll { $0.id == id }
        persist()
    }

    private func start(id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }),
              job.state == .queued else { return }
        update(id: id) {
            $0.state = .preparing
            $0.failureMessage = nil
        }
        do {
            if let mediaId = job.mediaId {
                update(id: id) { $0.state = .processing }
                let media = try await api.conversationalMediaStatus(
                    inVibe: job.vibeSlug,
                    mediaId: mediaId
                )
                try await applyProcessingResult(media, to: id, job: job)
                return
            }
            let fileURL = URL(fileURLWithPath: job.localFilePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let preparation = try await api.prepareConversationalMediaUpload(
                toVibe: job.vibeSlug,
                waveId: job.waveId,
                kind: job.kind,
                mimeType: job.mimeType,
                size: size,
                durationMilliseconds: job.durationMilliseconds
            )
            update(id: id) {
                $0.state = .uploading
                $0.mediaId = preparation.mediaId
                $0.objectKey = preparation.objectKey
            }
            try await RippleBackgroundUploadDriver.shared.upload(
                preparation: preparation,
                fileURL: fileURL,
                mimeType: job.mimeType
            ) { [weak self] value in
                Task { @MainActor in self?.update(id: id) { $0.progress = value } }
            }
            update(id: id) {
                $0.state = .processing
                $0.progress = 1
            }
            let media = try await api.completeConversationalMediaUpload(
                inVibe: job.vibeSlug,
                mediaId: preparation.mediaId,
                objectKey: preparation.objectKey
            )
            try await applyProcessingResult(media, to: id, job: job)
        } catch {
            update(id: id) {
                $0.state = .failed
                $0.failureMessage = error.localizedDescription
            }
        }
    }

    private func applyProcessingResult(
        _ initialMedia: ConversationalMedia,
        to id: UUID,
        job: RippleMediaUploadJob
    ) async throws {
        var media = initialMedia
        for attempt in 0..<20 {
            switch media.status {
            case .ready:
                update(id: id) {
                    $0.media = media
                    $0.state = .ready
                    $0.failureMessage = nil
                }
                return
            case .failed, .unavailable:
                update(id: id) {
                    $0.media = media
                    $0.state = .failed
                    $0.failureMessage = media.failureReason ?? "The media could not be processed."
                }
                return
            case .preparing, .uploading, .processing:
                update(id: id) {
                    $0.media = media
                    $0.state = .processing
                }
                guard let mediaId = jobs.first(where: { $0.id == id })?.mediaId else {
                    throw RippleMediaUploadError.invalidResponse
                }
                if attempt == 19 { break }
                try await Task.sleep(for: .seconds(2))
                media = try await api.conversationalMediaStatus(
                    inVibe: job.vibeSlug,
                    mediaId: mediaId
                )
            }
        }
        update(id: id) {
            $0.state = .failed
            $0.failureMessage = "Media is still processing. Retry to check its status."
        }
    }

    private func update(id: UUID, mutation: (inout RippleMediaUploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
        persist()
    }

    private func persistentFileURL(
        sourceURL: URL,
        kind: ConversationalMediaKind
    ) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("RippleMediaUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty
            ? (kind == .voice ? "m4a" : "mov")
            : sourceURL.pathExtension
        let destination = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        if sourceURL.standardizedFileURL != destination.standardizedFileURL {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    private func persist() {
        guard let data = try? encoder.encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
