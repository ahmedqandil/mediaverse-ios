import Foundation

public enum MatrixCrossClientEventDisposition: Equatable, Sendable {
    case nativeMatrix
    case crossClientCustom
    case preserveHidden
    case reject
}

public struct MatrixCrossClientDeepLinkTarget: Equatable, Sendable {
    public let roomID: String
    public let eventID: String?

    public init(roomID: String, eventID: String?) {
        self.roomID = roomID
        self.eventID = eventID
    }
}

/// The explicit compatibility boundary shared by Vibes Web and Swift.
///
/// Element treats unknown room events as durable Matrix history without
/// executing product behavior, and resolves matrix.to room/event permalinks
/// through one validated navigation target. Swift follows those same rules.
public enum MatrixCrossClientCompatibility {
    public static let customEventTypes: Set<String> = [
        "com.westreem.share.v1",
        "com.westreem.event_ref.v1",
        "com.westreem.room.rules.v1",
        "com.westreem.live.speaker.v1",
        "com.westreem.live.stage.v1",
        "com.westreem.public_sharing.v1",
        "com.westreem.watch_party.v1",
    ]

    public static func disposition(
        for eventType: String
    ) -> MatrixCrossClientEventDisposition {
        guard isSafeEventType(eventType) else { return .reject }
        if customEventTypes.contains(eventType) { return .crossClientCustom }
        if eventType.hasPrefix("m.") || eventType.hasPrefix("org.matrix.") {
            return .nativeMatrix
        }
        return .preserveHidden
    }

    public static func resolveDeepLink(
        _ value: String
    ) -> MatrixCrossClientDeepLinkTarget? {
        guard !value.isEmpty, value.utf8.count <= 2_048 else { return nil }

        if value.hasPrefix("/vibes/rooms/") {
            let components = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            let encodedRoom = String(components[0].dropFirst("/vibes/rooms/".count))
                .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let encodedEvent = components.count == 2
                ? encodedQueryValue("event", query: String(components[1]))
                : nil
            return canonicalTarget(encodedRoom: encodedRoom, encodedEvent: encodedEvent)
        }

        guard let components = URLComponents(string: value) else { return nil }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        let isTrustedVibesWebLink = scheme == "https"
            && ["westreem.com", "www.westreem.com"].contains(host)
        let isVibesAppLink = scheme == "westreem" && host == "vibes"
        if isTrustedVibesWebLink || isVibesAppLink {
            let path = isVibesAppLink
                ? "/vibes\(components.percentEncodedPath)"
                : components.percentEncodedPath
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            return resolveDeepLink("\(path)\(query)")
        }

        guard scheme == "https",
              host == "matrix.to",
              let fragment = components.percentEncodedFragment,
              fragment.hasPrefix("/")
        else { return nil }
        let target = fragment.dropFirst().split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard let encodedRoom = target.first else { return nil }
        let encodedEvent = target.count > 1
            ? String(target[1]).split(separator: "?", maxSplits: 1).first.map(String.init)
            : nil
        return canonicalTarget(
            encodedRoom: String(encodedRoom),
            encodedEvent: encodedEvent
        )
    }

    private static func encodedQueryValue(
        _ name: String,
        query: String
    ) -> String? {
        for item in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = item.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.first?.removingPercentEncoding == name else { continue }
            return pair.count == 2 ? String(pair[1]) : ""
        }
        return nil
    }

    private static func canonicalTarget(
        encodedRoom: String,
        encodedEvent: String?
    ) -> MatrixCrossClientDeepLinkTarget? {
        guard let roomID = encodedRoom.removingPercentEncoding,
              validRoomID(roomID)
        else { return nil }
        let eventID: String?
        if let encodedEvent, !encodedEvent.isEmpty {
            guard let decoded = encodedEvent.removingPercentEncoding,
                  validEventID(decoded)
            else { return nil }
            eventID = decoded
        } else {
            eventID = nil
        }
        return MatrixCrossClientDeepLinkTarget(roomID: roomID, eventID: eventID)
    }

    private static func validRoomID(_ value: String) -> Bool {
        guard value.count <= 255,
              value.first == "!",
              let colon = value.firstIndex(of: ":"),
              colon > value.startIndex,
              value.index(after: colon) < value.endIndex
        else { return false }
        return !value.contains(where: { $0.isWhitespace })
    }

    private static func validEventID(_ value: String) -> Bool {
        guard value.count <= 255, value.first == "$", value.count > 1 else {
            return false
        }
        return !value.contains(where: { $0.isWhitespace })
    }

    private static func isSafeEventType(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }
}
