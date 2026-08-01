import Foundation

enum MatrixNativeAttachmentKind: String, Codable, Equatable, Sendable {
    case image
    case audio
    case voice
    case video
    case file
    case sticker
}

struct MatrixNativeUpload: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: MatrixNativeAttachmentKind
    let data: Data
    let filename: String
    let mimeType: String
    let width: UInt64?
    let height: UInt64?
    let duration: TimeInterval?
    /// MSC3245 waveform data: 0–1024 amplitude samples, max 120 entries.
    /// Non-nil only for voice messages where waveform capture succeeded.
    let waveform: [Int]?

    init(
        id: UUID = UUID(),
        kind: MatrixNativeAttachmentKind,
        data: Data,
        filename: String,
        mimeType: String,
        width: UInt64? = nil,
        height: UInt64? = nil,
        duration: TimeInterval? = nil,
        waveform: [Int]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = data
        self.filename = filename
        self.mimeType = MatrixNativeMediaPolicy.baseMimeType(mimeType) ?? mimeType.lowercased()
        self.width = width
        self.height = height
        self.duration = duration
        self.waveform = waveform
    }
}

struct MatrixNativeMediaDescriptor: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: MatrixNativeAttachmentKind
    let filename: String
    let mimeType: String?
    let size: UInt64?
    let width: UInt64?
    let height: UInt64?
    let duration: TimeInterval?
    let sourceJSON: String
    let thumbnailSourceJSON: String?
    let thumbnailMimeType: String?
    let thumbnailSize: UInt64?
    let thumbnailWidth: UInt64?
    let thumbnailHeight: UInt64?
    /// MSC3245 waveform data (0–1024 amplitude samples). Populated from the
    /// matrix-rust-components-swift `AudioMessageContent.voice?.waveform` property
    /// for received voice messages. Nil when not a voice message or not available.
    let waveform: [UInt16]?

    init(
        id: String,
        kind: MatrixNativeAttachmentKind,
        filename: String,
        mimeType: String?,
        size: UInt64?,
        width: UInt64?,
        height: UInt64?,
        duration: TimeInterval?,
        sourceJSON: String,
        thumbnailSourceJSON: String? = nil,
        thumbnailMimeType: String? = nil,
        thumbnailSize: UInt64? = nil,
        thumbnailWidth: UInt64? = nil,
        thumbnailHeight: UInt64? = nil,
        waveform: [UInt16]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.sourceJSON = sourceJSON
        self.thumbnailSourceJSON = thumbnailSourceJSON
        self.thumbnailMimeType = thumbnailMimeType
        self.thumbnailSize = thumbnailSize
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.waveform = waveform
    }
}

extension MatrixNativeMediaDescriptor {
    /// Element prefers the event-provided thumbnail because it is smaller and
    /// its MediaSource retains the encrypted-file metadata in encrypted rooms.
    var authenticatedThumbnail: MatrixNativeMediaDescriptor? {
        guard let thumbnailSourceJSON, !thumbnailSourceJSON.isEmpty else { return nil }
        return MatrixNativeMediaDescriptor(
            id: "\(id)::thumbnail",
            kind: .image,
            filename: "thumbnail-\(filename)",
            mimeType: thumbnailMimeType,
            size: thumbnailSize,
            width: thumbnailWidth,
            height: thumbnailHeight,
            duration: nil,
            sourceJSON: thumbnailSourceJSON
        )
    }

    var effectiveKind: MatrixNativeAttachmentKind {
        if kind == .sticker { return .sticker }

        let lowercasedName = filename.lowercased()
        let lowercasedMime = effectiveMimeType ?? ""

        if kind == .audio || lowercasedMime.hasPrefix("audio/") {
            // Case-insensitive ranged search avoids copying the whole event
            // JSON on every render.
            if sourceJSON.range(of: "org.matrix.msc3245.voice", options: .caseInsensitive) != nil
                || sourceJSON.range(of: "\"voice\"", options: .caseInsensitive) != nil
                || lowercasedName.contains("voice") {
                return .voice
            }
            return .audio
        }

        if lowercasedMime.hasPrefix("image/") { return .image }
        if lowercasedMime.hasPrefix("video/") { return .video }
        return kind
    }

    var effectiveMimeType: String? {
        if let base = MatrixNativeMediaPolicy.baseMimeType(mimeType) { return base }
        let lowercasedName = filename.lowercased()
        if lowercasedName.hasSuffix(".jpg") || lowercasedName.hasSuffix(".jpeg") { return "image/jpeg" }
        if lowercasedName.hasSuffix(".png") { return "image/png" }
        if lowercasedName.hasSuffix(".gif") { return "image/gif" }
        if lowercasedName.hasSuffix(".heic") { return "image/heic" }
        if lowercasedName.hasSuffix(".heif") { return "image/heif" }
        if lowercasedName.hasSuffix(".webp") { return "image/webp" }
        if lowercasedName.hasSuffix(".mp4") || lowercasedName.hasSuffix(".m4v") { return "video/mp4" }
        if lowercasedName.hasSuffix(".mov") { return "video/quicktime" }
        if lowercasedName.hasSuffix(".m4a") { return "audio/mp4" }
        if lowercasedName.hasSuffix(".mp3") { return "audio/mpeg" }
        if lowercasedName.hasSuffix(".aac") { return "audio/aac" }
        if lowercasedName.hasSuffix(".wav") { return "audio/wav" }
        if lowercasedName.hasSuffix(".webm") {
            return filename.lowercased().contains("voice") ? "audio/webm" : "video/webm"
        }
        return nil
    }
}

struct MatrixNativePollOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let voteCount: Int
}

struct MatrixNativePollDescriptor: Codable, Equatable, Sendable {
    let question: String
    let options: [MatrixNativePollOption]
    let maxSelections: UInt64
    let isDisclosed: Bool
    let hasEnded: Bool
    let selectedOptionIDs: Set<String>
}

enum MatrixNativePollSelectionContract {
    static func toggled(
        _ selection: Set<String>,
        optionID: String,
        maximum: UInt64
    ) -> Set<String> {
        var next = selection
        if next.remove(optionID) != nil { return next }
        let limit = max(1, Int(maximum))
        if limit == 1 { return [optionID] }
        if next.count < limit { next.insert(optionID) }
        return next
    }
}

enum MatrixNativeMediaError: LocalizedError, Equatable {
    case encryptedMediaUnavailable
    case invalidAttachment
    case unsupportedAttachment
    case attachmentTooLarge(limitBytes: UInt64)
    case totalTooLarge(limitBytes: UInt64)
    case tooManyAttachments(limit: Int)
    case emptyPoll
    case invalidPollOptions
    case mediaUnavailable

    var errorDescription: String? {
        switch self {
        case .encryptedMediaUnavailable:
            "This older protected attachment is unavailable on this device."
        case .invalidAttachment:
            "This attachment did not pass the Vibes safety checks."
        case .unsupportedAttachment:
            "This attachment type is not supported in Vibes."
        case .attachmentTooLarge(let limit):
            "This attachment is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) limit."
        case .totalTooLarge(let limit):
            "These attachments exceed the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) message limit."
        case .tooManyAttachments(let limit):
            "A message can contain up to \(limit) attachments."
        case .emptyPoll:
            "Add a question before publishing the poll."
        case .invalidPollOptions:
            "A poll needs between 2 and 10 distinct answers."
        case .mediaUnavailable:
            "This attachment is unavailable or could not be verified."
        }
    }
}

enum MatrixNativeMediaPolicy {
    static let maximumAttachmentCount = 10
    static let maximumImageBytes: UInt64 = 25 * 1_024 * 1_024
    static let maximumAudioBytes: UInt64 = 50 * 1_024 * 1_024
    static let maximumVideoBytes: UInt64 = 200 * 1_024 * 1_024
    static let maximumFileBytes: UInt64 = 100 * 1_024 * 1_024
    static let maximumMessageBytes: UInt64 = 250 * 1_024 * 1_024
    static let maximumVoiceDuration = MatrixNativeMediaSafetyContract.maximumVoiceDuration
    static let maximumVideoDuration = MatrixNativeMediaSafetyContract.maximumVideoDuration

    private static let imageTypes = Set([
        "image/jpeg", "image/png", "image/gif", "image/heic", "image/heif", "image/webp",
    ])
    private static let audioTypes = Set([
        "audio/mp4", "audio/m4a", "audio/mpeg", "audio/aac", "audio/wav", "audio/x-wav", "audio/webm",
    ])
    private static let videoTypes = Set([
        "video/mp4", "video/quicktime", "video/webm",
    ])
    private static let fileTypes = Set([
        "application/pdf",
        "application/json",
        "application/zip",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "text/plain",
        "text/csv",
    ])

    /// Reduces a MIME string to its lowercase base type. Web clients record
    /// voice messages with parameterized types like "audio/webm;codecs=opus";
    /// allowlist and signature checks match on the base type only.
    static func baseMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw
            .components(separatedBy: ";")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return base.isEmpty ? nil : base
    }

    static func validate(
        _ uploads: [MatrixNativeUpload],
        serverMaximumBytes: UInt64,
        requiresBoundedOutboundDuration: Bool = true
    ) throws {
        guard !uploads.isEmpty else { throw MatrixNativeMediaError.invalidAttachment }
        guard uploads.count <= maximumAttachmentCount else {
            throw MatrixNativeMediaError.tooManyAttachments(limit: maximumAttachmentCount)
        }

        var total: UInt64 = 0
        for upload in uploads {
            guard !upload.data.isEmpty, !upload.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            guard allowedTypes(for: upload.kind).contains(upload.mimeType) else {
                throw MatrixNativeMediaError.unsupportedAttachment
            }
            guard !hasExecutableSignature(upload.data) else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            guard signatureMatchesDeclaredType(upload) else {
                throw MatrixNativeMediaError.invalidAttachment
            }

            let size = UInt64(upload.data.count)
            let localLimit = maximumBytes(for: upload.kind)
            let effectiveLimit = min(localLimit, serverMaximumBytes)
            guard size <= effectiveLimit else {
                throw MatrixNativeMediaError.attachmentTooLarge(limitBytes: effectiveLimit)
            }
            switch upload.kind {
            case .video:
                guard !requiresBoundedOutboundDuration
                    || MatrixNativeMediaSafetyContract.acceptsDuration(
                        upload.duration,
                        for: .video
                    ) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
            case .voice:
                guard !requiresBoundedOutboundDuration
                    || MatrixNativeMediaSafetyContract.acceptsDuration(
                        upload.duration,
                        for: .voice
                    ) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
            case .audio:
                guard MatrixNativeMediaSafetyContract.acceptsDuration(
                    upload.duration,
                    for: .audio
                ) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
            case .image, .file, .sticker:
                break
            }
            total += size
        }
        let totalLimit = min(maximumMessageBytes, serverMaximumBytes)
        guard total <= totalLimit else {
            throw MatrixNativeMediaError.totalTooLarge(limitBytes: totalLimit)
        }
    }

    static func validateDownload(size: UInt64?, receivedBytes: Int, serverMaximumBytes: UInt64) throws {
        let limit = min(maximumVideoBytes, serverMaximumBytes)
        if let size, size > limit {
            throw MatrixNativeMediaError.attachmentTooLarge(limitBytes: limit)
        }
        guard receivedBytes > 0, UInt64(receivedBytes) <= limit else {
            throw MatrixNativeMediaError.mediaUnavailable
        }
    }

    static func validateDownloadedData(
        _ data: Data,
        descriptor: MatrixNativeMediaDescriptor
    ) throws {
        guard let mimeType = descriptor.effectiveMimeType,
              descriptor.size == nil || descriptor.size == UInt64(data.count) else {
            throw MatrixNativeMediaError.mediaUnavailable
        }
        let validationKind = descriptor.effectiveKind
        let candidate = MatrixNativeUpload(
            kind: validationKind,
            data: data,
            filename: descriptor.filename,
            mimeType: mimeType,
            width: descriptor.width,
            height: descriptor.height,
            duration: descriptor.duration
        )
        try validate(
            [candidate],
            serverMaximumBytes: maximumBytes(for: validationKind),
            requiresBoundedOutboundDuration: false
        )
    }

    static func validatePoll(question: String, options: [String]) throws -> (String, [String]) {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty, cleanedQuestion.count <= 500 else {
            throw MatrixNativeMediaError.emptyPoll
        }
        let cleaned = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard (2...10).contains(cleaned.count),
              cleaned.allSatisfy({ $0.count <= 200 }),
              Set(cleaned.map { $0.lowercased() }).count == cleaned.count else {
            throw MatrixNativeMediaError.invalidPollOptions
        }
        return (cleanedQuestion, cleaned)
    }

    private static func allowedTypes(for kind: MatrixNativeAttachmentKind) -> Set<String> {
        switch kind {
        case .image, .sticker: imageTypes
        case .audio, .voice: audioTypes
        case .video: videoTypes
        case .file: fileTypes
        }
    }

    private static func maximumBytes(for kind: MatrixNativeAttachmentKind) -> UInt64 {
        switch kind {
        case .image, .sticker: maximumImageBytes
        case .audio, .voice: maximumAudioBytes
        case .video: maximumVideoBytes
        case .file: maximumFileBytes
        }
    }

    private static func hasExecutableSignature(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(4))
        guard !bytes.isEmpty else { return true }
        return bytes.starts(with: [0x4D, 0x5A])
            || bytes.starts(with: [0x7F, 0x45, 0x4C, 0x46])
            || bytes == [0xCF, 0xFA, 0xED, 0xFE]
            || bytes == [0xFE, 0xED, 0xFA, 0xCF]
            || data.prefix(2) == Data("#!".utf8)
    }

    private static func signatureMatchesDeclaredType(_ upload: MatrixNativeUpload) -> Bool {
        let data = upload.data
        let bytes = Array(data.prefix(12))
        switch upload.mimeType {
        case "image/jpeg":
            return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png":
            return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/gif":
            return data.prefix(3) == Data("GIF".utf8)
        case "image/webp":
            return data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        case "image/heic", "image/heif", "video/mp4", "video/quicktime", "audio/mp4", "audio/m4a":
            return data.dropFirst(4).prefix(4) == Data("ftyp".utf8)
        case "audio/webm", "video/webm":
            return bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
        case "audio/mpeg":
            return data.prefix(3) == Data("ID3".utf8)
                || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)
        case "audio/aac":
            return bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0
        case "audio/wav", "audio/x-wav":
            return data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        case "application/pdf":
            return data.prefix(5) == Data("%PDF-".utf8)
        case "application/zip",
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return bytes.starts(with: [0x50, 0x4B])
        case "text/plain", "text/csv", "application/json":
            return !data.prefix(1_024).contains(0)
        default:
            return false
        }
    }
}
