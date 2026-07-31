import CryptoKit
import Foundation

enum MatrixNativeRoomAttachmentCategory: String, CaseIterable, Codable, Sendable {
    case media
    case documents
    case links
}

struct MatrixNativeRoomMediaAttachment: Codable, Equatable, Sendable {
    let descriptor: MatrixNativeMediaDescriptor
    let mediaKind: MatrixNativeAttachmentKind
    let title: String
    let duration: TimeInterval?
    let width: UInt64?
    let height: UInt64?
}

struct MatrixNativeRoomDocumentAttachment: Codable, Equatable, Sendable {
    let descriptor: MatrixNativeMediaDescriptor
    let title: String
    let fileExtension: String
    let size: UInt64?
    let mimeType: String?
}

struct MatrixNativeRoomLinkAttachment: Codable, Equatable, Sendable {
    let url: URL
    let title: String
    let summary: String?
    let domain: String
    let previewDescriptor: MatrixNativeMediaDescriptor?
}

enum MatrixNativeRoomAttachmentPayload: Codable, Equatable, Sendable {
    case media(MatrixNativeRoomMediaAttachment)
    case document(MatrixNativeRoomDocumentAttachment)
    case link(MatrixNativeRoomLinkAttachment)

    var category: MatrixNativeRoomAttachmentCategory {
        switch self {
        case .media: .media
        case .document: .documents
        case .link: .links
        }
    }
}

struct MatrixNativeRoomAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let eventReference: MatrixNativeEventReference
    let senderID: String
    let timestamp: Date
    let payload: MatrixNativeRoomAttachmentPayload
    let canDeleteForEveryone: Bool
}

struct MatrixNativeRoomAttachmentSection: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [MatrixNativeRoomAttachment]
}

struct MatrixNativeRoomAttachmentGalleryState: Codable, Equatable, Sendable {
    var items: [MatrixNativeRoomAttachment]
    var selection: Set<String> = []
    var activePreviewIndex: Int?
    var starredIDs: Set<String> = []
    var loadedPageCount = 1
    var hasMore = false

    static let pageSize = 60

    var visibleItems: [MatrixNativeRoomAttachment] {
        Array(items.prefix(loadedPageCount * Self.pageSize))
    }

    mutating func loadNextPageIfNeeded(visibleItemID: String) {
        guard hasMore, visibleItems.last?.id == visibleItemID else { return }
        loadedPageCount += 1
        hasMore = visibleItems.count < items.count
    }

    mutating func toggleSelection(_ id: String) {
        if selection.remove(id) == nil { selection.insert(id) }
    }

    mutating func toggleStarredSelection() {
        let allSelectedAreStarred = !selection.isEmpty && selection.allSatisfy(starredIDs.contains)
        if allSelectedAreStarred { starredIDs.subtract(selection) } else { starredIDs.formUnion(selection) }
    }
}

enum MatrixNativeRoomAttachmentDerivation {
    private struct SectionIdentity: Hashable {
        let id: String
        let title: String
    }

    static func attachments(from timeline: [MatrixTimelineItem]) -> [MatrixNativeRoomAttachment] {
        timeline
            .flatMap(attachments)
            .sorted { left, right in
                if left.timestamp == right.timestamp { return left.id < right.id }
                return left.timestamp > right.timestamp
            }
    }

    static func sections(
        from attachments: [MatrixNativeRoomAttachment],
        category: MatrixNativeRoomAttachmentCategory,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MatrixNativeRoomAttachmentSection] {
        let filtered = attachments.filter { $0.payload.category == category }
        let grouped = Dictionary(grouping: filtered) { attachment in
            sectionIdentity(for: attachment.timestamp, now: now, calendar: calendar)
        }
        return grouped.map { identity, items in
            MatrixNativeRoomAttachmentSection(
                id: identity.id,
                title: identity.title,
                items: items.sorted { $0.timestamp > $1.timestamp }
            )
        }
        .sorted { ($0.items.first?.timestamp ?? .distantPast) > ($1.items.first?.timestamp ?? .distantPast) }
    }

    private static func attachments(from item: MatrixTimelineItem) -> [MatrixNativeRoomAttachment] {
        var derived: [MatrixNativeRoomAttachment] = item.media.enumerated().map { index, descriptor in
            let effectiveKind = descriptor.effectiveKind
            let payload: MatrixNativeRoomAttachmentPayload
            switch effectiveKind {
            case .image, .video, .sticker:
                payload = .media(MatrixNativeRoomMediaAttachment(
                    descriptor: descriptor,
                    mediaKind: effectiveKind,
                    title: descriptor.filename,
                    duration: descriptor.duration,
                    width: descriptor.width,
                    height: descriptor.height
                ))
            case .file, .audio, .voice:
                payload = .document(MatrixNativeRoomDocumentAttachment(
                    descriptor: descriptor,
                    title: descriptor.filename,
                    fileExtension: safeExtension(descriptor.filename),
                    size: descriptor.size,
                    mimeType: descriptor.effectiveMimeType
                ))
            }
            return MatrixNativeRoomAttachment(
                id: "\(item.id)::media::\(descriptor.id)::\(index)",
                eventReference: item.reference,
                senderID: item.senderID,
                timestamp: item.timestamp,
                payload: payload,
                canDeleteForEveryone: item.actions.canRedact
            )
        }

        for (index, url) in safeWebURLs(in: item.body).enumerated() {
            guard let domain = safeDomain(url) else { continue }
            derived.append(MatrixNativeRoomAttachment(
                id: "\(item.id)::link::\(index)::\(url.absoluteString)",
                eventReference: item.reference,
                senderID: item.senderID,
                timestamp: item.timestamp,
                payload: .link(MatrixNativeRoomLinkAttachment(
                    url: url,
                    title: url.absoluteString,
                    summary: nil,
                    domain: domain,
                    previewDescriptor: nil
                )),
                canDeleteForEveryone: item.actions.canRedact
            ))
        }
        return derived
    }

    private static func sectionIdentity(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> SectionIdentity {
        if calendar.isDate(date, inSameDayAs: now) {
            return SectionIdentity(id: "today", title: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return SectionIdentity(id: "yesterday", title: "Yesterday")
        }
        let components = calendar.dateComponents([.year, .month], from: date)
        let id = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        return SectionIdentity(
            id: id,
            title: date.formatted(.dateTime.month(.wide).year())
        )
    }

    private static func safeWebURLs(in body: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return detector.matches(in: body, options: [], range: range).compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.user == nil, url.password == nil,
                  safeDomain(url) != nil else { return nil }
            return url
        }
    }

    private static func safeDomain(_ url: URL) -> String? {
        guard var host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
              !host.isEmpty, host.count <= 253,
              !host.contains(" ") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func safeExtension(_ filename: String) -> String {
        String(URL(fileURLWithPath: filename).pathExtension.lowercased().prefix(12))
    }

}

struct MatrixNativeRoomAttachmentLocalState: Codable, Equatable, Sendable {
    var hiddenIDs: Set<String> = []
    var starredIDs: Set<String> = []
}

/// Bounded account-and-room scoped local preferences. UserDefaults is already
/// protected by the app container; opaque hashed keys avoid exposing Matrix IDs.
@MainActor
final class MatrixNativeRoomAttachmentLocalStore {
    static let shared = MatrixNativeRoomAttachmentLocalStore()
    private let defaults: UserDefaults
    private let maximumIDs = 1_000

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(accountID: String, roomID: String) -> MatrixNativeRoomAttachmentLocalState {
        guard !accountID.isEmpty, !roomID.isEmpty,
              let data = defaults.data(forKey: key(accountID: accountID, roomID: roomID)),
              let state = try? JSONDecoder().decode(MatrixNativeRoomAttachmentLocalState.self, from: data)
        else { return MatrixNativeRoomAttachmentLocalState() }
        return bounded(state)
    }

    func save(_ state: MatrixNativeRoomAttachmentLocalState, accountID: String, roomID: String) {
        guard !accountID.isEmpty, !roomID.isEmpty,
              let data = try? JSONEncoder().encode(bounded(state)) else { return }
        defaults.set(data, forKey: key(accountID: accountID, roomID: roomID))
    }

    func clear(accountID: String, roomID: String) {
        defaults.removeObject(forKey: key(accountID: accountID, roomID: roomID))
    }

    private func bounded(_ state: MatrixNativeRoomAttachmentLocalState) -> MatrixNativeRoomAttachmentLocalState {
        MatrixNativeRoomAttachmentLocalState(
            hiddenIDs: Set(state.hiddenIDs.sorted().prefix(maximumIDs)),
            starredIDs: Set(state.starredIDs.sorted().prefix(maximumIDs))
        )
    }

    private func key(accountID: String, roomID: String) -> String {
        let digest = SHA256.hash(data: Data("\(accountID)|\(roomID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "matrix.room.attachments.v1.\(digest)"
    }
}
