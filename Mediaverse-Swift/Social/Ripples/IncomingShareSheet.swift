import SwiftUI

/// Resolves content received from the iOS share sheet, then hands it to the
/// same native Echo experience used everywhere else in WeStreem.
struct IncomingShareSheet: View {
    let share: IncomingShare
    let onClose: () -> Void

    @State private var content: EchoContent?
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        Group {
            if let content {
                EchoVibeSheet(content: content) { _ in
                    onClose()
                }
            } else {
                NavigationStack {
                    VStack(spacing: 18) {
                        if let errorMessage {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(C.watch)
                            Text("This link could not be prepared")
                                .font(.headline)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(C.textMuted)
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                Task { await resolve() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(C.watch)
                        } else {
                            ProgressView()
                                .tint(C.watch)
                            Text("Preparing Echo…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.bg)
                    .navigationTitle("Echo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close", action: onClose)
                        }
                    }
                }
            }
        }
        .task { await resolve() }
    }

    @MainActor
    private func resolve() async {
        guard content == nil else { return }
        errorMessage = nil
        do {
            let result = try await api.resolveAttachment(url: share.url.absoluteString)
            let preview = result.preview
            guard let attachment = result.attachment.createAttachment else {
                throw IncomingShareError.unsupportedAttachment
            }
            content = EchoContent(
                attachment: attachment,
                eyebrow: preview?.kind?.uppercased() ?? "LINK",
                title: preview?.title ?? share.url.host ?? "Shared link",
                subtitle: preview?.subtitle ?? preview?.domain,
                imageURL: preview?.thumbnailURL ?? preview?.faviconURL,
                avatarURL: preview?.faviconURL,
                description: preview?.subtitle,
                sourceName: preview?.domain ?? share.url.host,
                isPortrait: preview?.kind?.lowercased() == "short"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum IncomingShareError: LocalizedError {
    case unsupportedAttachment

    var errorDescription: String? {
        "This type of link is not available for Echo yet."
    }
}
