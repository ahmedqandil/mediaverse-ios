import SwiftUI

/// A Westreem-owned entity prepared for an explicit share into Matrix Vibes.
///
/// This is presentation input only. The canonical URL, eligibility,
/// provenance and final Matrix event payload are resolved by the existing
/// Westreem bridge endpoint immediately before sending.
struct EchoContent {
    let entityType: MatrixNativeWestreemShareEntityType
    let entityID: String
    let eyebrow: String
    let title: String
    let subtitle: String?
    let imageURL: String?
    let avatarURL: String?
    let description: String?
    let sourceName: String?
    let isPortrait: Bool

    static func ripple(_ ripple: Ripple) -> EchoContent {
        let attachment = ripple.attachments.first
        let video = attachment?.video
        let clipVideo = attachment?.userPost?.video
        let clipEpisode = attachment?.userPost?.episode
        let previewImage = attachment?.imageURL
            ?? attachment?.linkImageURL
            ?? video?.thumbnailURL
            ?? clipVideo?.thumbnailURL
            ?? clipEpisode?.thumbnailUrl
        let isPortrait = video?.type?.lowercased() == "short"
            || ((video?.height ?? 0) > (video?.width ?? Int.max))
        let authorName = ripple.author.name
            ?? ripple.author.handle.map { "@\($0)" }
            ?? "WeStreem user"
        return EchoContent(
            entityType: .atmoPost,
            entityID: ripple.id,
            eyebrow: "ATMO POST",
            title: ripple.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? ripple.body!
                : "Post by \(authorName)",
            subtitle: "Personal Atmo",
            imageURL: previewImage,
            avatarURL: ripple.author.image,
            description: attachment?.linkDescription
                ?? attachment?.collection?.description
                ?? attachment?.userPost?.caption,
            sourceName: authorName,
            isPortrait: isPortrait
        )
    }

    static func video(
        id: String,
        title: String,
        thumbnailURL: String?,
        isShort: Bool = false,
        description: String? = nil,
        sourceName: String? = "WeStreem"
    ) -> EchoContent {
        EchoContent(
            entityType: isShort ? .short : .video,
            entityID: id,
            eyebrow: isShort ? "SHORT" : "VIDEO",
            title: title,
            subtitle: "WeStreem",
            imageURL: thumbnailURL,
            avatarURL: nil,
            description: description,
            sourceName: sourceName,
            isPortrait: isShort
        )
    }

    static func collection(
        id: String,
        title: String,
        imageURL: String?,
        description: String? = nil,
        sourceName: String? = "WeStreem Collection"
    ) -> EchoContent {
        EchoContent(
            entityType: .collection,
            entityID: id,
            eyebrow: "COLLECTION",
            title: title,
            subtitle: "WeStreem Collection",
            imageURL: imageURL,
            avatarURL: nil,
            description: description,
            sourceName: sourceName,
            isPortrait: false
        )
    }

    static func clip(
        id: String,
        title: String,
        imageURL: String?,
        description: String? = nil,
        sourceName: String? = "WeStreem Clipping"
    ) -> EchoContent {
        EchoContent(
            entityType: .clipping,
            entityID: id,
            eyebrow: "CLIPPING",
            title: title,
            subtitle: "WeStreem Clipping",
            imageURL: imageURL,
            avatarURL: nil,
            description: description,
            sourceName: sourceName,
            isPortrait: false
        )
    }

    static func event(
        id: String,
        title: String,
        imageURL: String?,
        summary: String?,
        sourceName: String?
    ) -> EchoContent {
        EchoContent(
            entityType: .event,
            entityID: id,
            eyebrow: "EVENT",
            title: title,
            subtitle: "WeStreem Event",
            imageURL: imageURL,
            avatarURL: nil,
            description: summary,
            sourceName: sourceName,
            isPortrait: false
        )
    }
}

private struct MatrixEchoDestination: Identifiable, Equatable {
    let id: String
    let waveName: String
    let vibeName: String
    let avatarURL: String?
}

/// Chat-native internal share sheet.
///
/// Destinations and writes are Matrix-native. No legacy Fan Club/Vibe API is
/// consulted, and no Vibe activity is written to Prisma first.
struct EchoVibeSheet: View {
    let content: EchoContent
    let onEchoed: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var destinations: [MatrixEchoDestination] = []
    @State private var selectedRoomIDs = Set<String>()
    @State private var query = ""
    @State private var quote = ""
    @State private var isLoading = true
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(ripple: Ripple, onEchoed: @escaping (Int) -> Void) {
        content = .ripple(ripple)
        self.onEchoed = onEchoed
    }

    init(content: EchoContent, onEchoed: @escaping (Int) -> Void = { _ in }) {
        self.content = content
        self.onEchoed = onEchoed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    preview

                    if isLoading {
                        ProgressView("Loading Waves…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        destinationPicker
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("echo-error")
                    }
                    if let successMessage {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("echo-success")
                    }
                }
                .padding(16)
            }
            .background(C.bg)
            .navigationTitle("Echo to Vibes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .safeAreaInset(edge: .bottom) {
                chatComposer
            }
        }
        .task(id: matrixSession.isReady) {
            await loadDestinations()
        }
    }

    private var preview: some View {
        HStack(spacing: 12) {
            previewArtwork

            VStack(alignment: .leading, spacing: 4) {
                Text(content.eyebrow)
                    .font(.caption2.bold())
                    .foregroundStyle(C.watch)
                Text(content.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text.opacity(0.92))
                    .lineLimit(2)
                if let source = content.sourceName ?? content.subtitle {
                    Label(source, systemImage: "wave.3.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 96)
        .padding(12)
        .background(C.elevated.opacity(0.82))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Content being Echoed: \(content.title)")
    }

    @ViewBuilder
    private var previewArtwork: some View {
        if let imageURL = content.imageURL {
            CachedRemoteImage(
                url: C.mediaURL(imageURL),
                targetSize: CGSize(
                    width: content.isPortrait ? 64 : 144,
                    height: 96
                )
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                C.elevated
            }
            .frame(width: content.isPortrait ? 64 : 144, height: 96)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            SocialIdentityAvatar(
                image: content.avatarURL,
                name: content.title,
                size: 64
            )
        }
    }

    @ViewBuilder
    private var destinationPicker: some View {
        Text("Send to a Wave")
            .font(.headline)
            .foregroundStyle(C.text)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(C.textMuted)
                TextField("Search Vibes and Waves", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("matrix-echo-destination-search")
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 46)
            .background(C.elevated)
            .clipShape(Capsule())

            if destinations.isEmpty {
                Text("Join a Vibe with a Wave before sending an Echo.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Start typing to find a Vibe conversation.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if matchingDestinations.isEmpty {
                Text("No matching Waves")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(matchingDestinations) { destination in
                    destinationRow(destination)
                }
            }
        }

        if !selectedRoomIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recipients")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Clear") { selectedRoomIDs.removeAll() }
                        .font(.caption.bold())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedDestinations) { destination in
                            HStack(spacing: 6) {
                                SocialIdentityAvatar(
                                    image: destination.avatarURL,
                                    name: destination.waveName,
                                    size: 24
                                )
                                Text(destination.waveName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Button {
                                    selectedRoomIDs.remove(destination.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(C.textMuted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(destination.waveName)")
                            }
                            .padding(.leading, 5)
                            .padding(.trailing, 8)
                            .padding(.vertical, 5)
                            .background(C.elevated)
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private var selectedDestinations: [MatrixEchoDestination] {
        destinations.filter { selectedRoomIDs.contains($0.id) }
    }

    private var chatComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Add a message (optional)", text: $quote, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("matrix-echo-optional-message")

            Button {
                Task { await publish() }
            } label: {
                Group {
                    if isPublishing {
                        ProgressView().tint(C.bg)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                .frame(width: 44, height: 44)
                .foregroundStyle(C.bg)
                .background(selectedRoomIDs.isEmpty ? C.textTertiary : C.watch)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(selectedRoomIDs.isEmpty || isPublishing)
            .accessibilityLabel(
                selectedRoomIDs.isEmpty
                    ? "Select a Wave"
                    : "Echo to \(selectedRoomIDs.count) Wave\(selectedRoomIDs.count == 1 ? "" : "s")"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(C.borderSubtle) }
    }

    private var matchingDestinations: [MatrixEchoDestination] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return [] }
        return destinations.filter {
            "\($0.waveName) \($0.vibeName)".lowercased().contains(normalized)
        }
    }

    private func destinationRow(_ destination: MatrixEchoDestination) -> some View {
        Button {
            if selectedRoomIDs.contains(destination.id) {
                selectedRoomIDs.remove(destination.id)
            } else {
                selectedRoomIDs.insert(destination.id)
            }
            errorMessage = nil
            successMessage = nil
        } label: {
            HStack(spacing: 10) {
                SocialIdentityAvatar(
                    image: destination.avatarURL,
                    name: destination.waveName,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.waveName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Text(destination.vibeName)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                Image(
                    systemName: selectedRoomIDs.contains(destination.id)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                    selectedRoomIDs.contains(destination.id)
                        ? C.watch
                        : C.textMuted
                )
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(destination.waveName), \(destination.vibeName)")
        .accessibilityValue(
            selectedRoomIDs.contains(destination.id) ? "Selected" : "Not selected"
        )
    }

    @MainActor
    private func loadDestinations() async {
        isLoading = true
        errorMessage = nil
        guard matrixSession.isReady else {
            destinations = []
            errorMessage = "Vibes is still connecting. Try again when synchronization finishes."
            isLoading = false
            return
        }
        do {
            let joinedSpaces = try await matrixSession.vibes().spaces
                .filter { $0.membership == .joined }
            var loaded: [MatrixEchoDestination] = []
            for space in joinedSpaces {
                let waves = try await matrixSession.waves(spaceID: space.id).rooms
                loaded.append(contentsOf: waves.compactMap { wave in
                    guard wave.membership == .joined, !wave.isNestedSpace else {
                        return nil
                    }
                    return MatrixEchoDestination(
                        id: wave.id,
                        waveName: wave.name,
                        vibeName: space.name,
                        avatarURL: wave.avatarURL ?? space.avatarURL
                    )
                })
            }
            destinations = Dictionary(
                grouping: loaded,
                by: \.id
            )
            .compactMap { $0.value.first }
            .sorted {
                "\($0.vibeName)\u{0}\($0.waveName)".localizedStandardCompare(
                    "\($1.vibeName)\u{0}\($1.waveName)"
                ) == .orderedAscending
            }
        } catch {
            destinations = []
            errorMessage = "Waves could not be loaded. Check your connection and try again."
        }
        isLoading = false
    }

    @MainActor
    private func publish() async {
        guard !selectedRoomIDs.isEmpty, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        successMessage = nil

        let requestID = UUID().uuidString.lowercased()
        let trimmedQuote = String(
            quote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000)
        )
        let selected = selectedDestinations
        var completed = 0
        var failedRoomIDs = Set<String>()
        var quoteFailures = 0

        do {
            let envelope = try await APIClient.shared.resolveMatrixShare(
                entityType: content.entityType,
                entityID: content.entityID,
                clientRequestID: requestID
            )
            for destination in selected {
                do {
                    try await matrixSession.sendWestreemReference(
                        envelope,
                        roomID: destination.id,
                        transactionID: "westreem-ios-reference-\(UUID().uuidString.lowercased())"
                    )
                    completed += 1

                    // MatrixRustSDK's current raw-event binding does not return
                    // the remote event ID, so the optional message is sent as
                    // the next standard Matrix message rather than fabricating
                    // an invalid relation.
                    if !trimmedQuote.isEmpty {
                        do {
                            try await matrixSession.sendText(
                                trimmedQuote,
                                roomID: destination.id,
                                transactionID: "westreem-ios-quote-\(UUID().uuidString.lowercased())"
                            )
                        } catch {
                            quoteFailures += 1
                        }
                    }
                } catch {
                    failedRoomIDs.insert(destination.id)
                }
            }
        } catch {
            failedRoomIDs = selectedRoomIDs
        }

        isPublishing = false
        if completed > 0 {
            onEchoed(completed)
            successMessage = "Echoed to \(completed) Wave\(completed == 1 ? "" : "s")."
            if quoteFailures > 0 {
                errorMessage = "The content arrived, but \(quoteFailures) optional message\(quoteFailures == 1 ? "" : "s") could not be sent."
            }
        }

        if failedRoomIDs.isEmpty, quoteFailures == 0 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } else {
            selectedRoomIDs = failedRoomIDs
            if completed == 0 {
                errorMessage = "This content is unavailable for Vibe sharing or could not reach the selected Waves."
            } else if !failedRoomIDs.isEmpty {
                errorMessage = "Some Waves could not receive this Echo. Only those destinations remain selected."
            }
        }
    }
}
