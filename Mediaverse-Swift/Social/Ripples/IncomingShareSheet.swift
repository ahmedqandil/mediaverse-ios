import SwiftUI

/// Hands content received from iOS to the same Matrix-native Echo experience
/// used by Westreem product surfaces. External arbitrary links are not turned
/// into Vibe events; only immutable, typed Westreem entities are eligible.
struct IncomingShareSheet: View {
    let share: IncomingShare
    let onClose: () -> Void

    @State private var content: EchoContent?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let content {
                EchoVibeSheet(content: content) { _ in
                    onClose()
                }
            } else {
                NavigationStack {
                    VStack(spacing: 18) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(C.watch)
                        Text("This link cannot be Echoed")
                            .font(.headline)
                        Text(
                            errorMessage
                                ?? "Open the item in WeStreem and choose Echo to Vibes so its identity can be verified."
                        )
                        .font(.footnote)
                        .foregroundStyle(C.textMuted)
                        .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.bg)
                    .navigationTitle("Echo to Vibes")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close", action: onClose)
                        }
                    }
                }
            }
        }
        .task { resolve() }
    }

    @MainActor
    private func resolve() {
        guard content == nil else { return }
        do {
            content = try EchoContent.typedWestreemShare(
                url: share.url,
                fallbackTitle: share.text
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum IncomingShareError: LocalizedError {
    case untrustedURL
    case missingImmutableIdentity
    case unsupportedEntity

    var errorDescription: String? {
        switch self {
        case .untrustedURL:
            "Only secure westreem.com links can be sent into Vibes."
        case .missingImmutableIdentity:
            "This link does not contain the verified WeStreem identity required for safe Vibe sharing."
        case .unsupportedEntity:
            "This WeStreem item is not one of the content types supported by Vibes."
        }
    }
}

private extension EchoContent {
    static func typedWestreemShare(
        url: URL,
        fallbackTitle: String?
    ) throws -> EchoContent {
        guard
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            host == "westreem.com" || host.hasSuffix(".westreem.com"),
            url.user == nil,
            url.password == nil,
            url.fragment == nil
        else {
            throw IncomingShareError.untrustedURL
        }

        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let query = (components?.queryItems ?? []).reduce(
            into: [String: String]()
        ) { values, item in
            if values[item.name] == nil, let value = item.value {
                values[item.name] = value
            }
        }
        let path = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let explicitType = query["entityType"].flatMap(
            MatrixNativeWestreemShareEntityType.init(rawValue:)
        )
        let explicitID = query["entityId"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let resolved: (MatrixNativeWestreemShareEntityType, String)
        if let explicitType, let explicitID, !explicitID.isEmpty {
            guard explicitType != .matrixEvent else {
                throw IncomingShareError.unsupportedEntity
            }
            resolved = (explicitType, explicitID)
        } else {
            guard path.count >= 2 else {
                throw IncomingShareError.missingImmutableIdentity
            }
            switch path[0].lowercased() {
            case "watch":
                resolved = (.video, path[1])
            case "shorts":
                resolved = (.short, path[1])
            case "collections":
                resolved = (.collection, path[1])
            case "shows":
                resolved = (.show, path[1])
            default:
                throw IncomingShareError.missingImmutableIdentity
            }
        }

        let title = fallbackTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle: String
        if let title, !title.isEmpty {
            displayTitle = String(title.prefix(500))
        } else {
            displayTitle = "WeStreem \(resolved.0.rawValue.replacingOccurrences(of: "_", with: " "))"
        }
        return EchoContent(
            entityType: resolved.0,
            entityID: String(resolved.1.prefix(512)),
            eyebrow: resolved.0.rawValue.replacingOccurrences(
                of: "_",
                with: " "
            ).uppercased(),
            title: displayTitle,
            subtitle: "WeStreem",
            imageURL: nil,
            avatarURL: nil,
            description: nil,
            sourceName: host,
            isPortrait: resolved.0 == .short
        )
    }
}
