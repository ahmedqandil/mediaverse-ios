import SwiftUI

struct EchoContent {
    let attachment: RippleCreateAttachment
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
            ?? "Westreem user"
        return EchoContent(
            attachment: .ripple(id: ripple.id),
            eyebrow: "RIPPLE",
            title: ripple.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? ripple.body!
                : "Ripple by \(authorName)",
            subtitle: ripple.club?.name,
            imageURL: previewImage,
            avatarURL: ripple.author.image,
            description: attachment?.linkDescription
                ?? attachment?.collection?.description
                ?? attachment?.userPost?.caption,
            sourceName: [authorName, ripple.club?.name]
                .compactMap { $0 }
                .joined(separator: " · "),
            isPortrait: isPortrait
        )
    }

    static func video(
        id: String,
        title: String,
        thumbnailURL: String?,
        isShort: Bool = false,
        description: String? = nil,
        sourceName: String? = "Westreem"
    ) -> EchoContent {
        EchoContent(
            attachment: .video(id: id),
            eyebrow: isShort ? "SHORT" : "VIDEO",
            title: title,
            subtitle: "Westreem",
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
        sourceName: String? = "Westreem Collection"
    ) -> EchoContent {
        EchoContent(
            attachment: .collection(id: id),
            eyebrow: "COLLECTION",
            title: title,
            subtitle: "Westreem Collection",
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
        sourceName: String? = "Westreem Clipping"
    ) -> EchoContent {
        EchoContent(
            attachment: .clip(id: id),
            eyebrow: "CLIP",
            title: title,
            subtitle: "Westreem Clipping",
            imageURL: imageURL,
            avatarURL: nil,
            description: description,
            sourceName: sourceName,
            isPortrait: false
        )
    }
}

struct EchoVibeSheet: View {
    let content: EchoContent
    let onEchoed: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destinations: [PostableVibe] = []
    @State private var selectedSlugs = Set<String>()
    @State private var query = ""
    @State private var quote = ""
    @State private var isQuoteEcho = false
    @State private var isLoading = true
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

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
                VStack(alignment: .leading, spacing: 16) {
                    preview

                    if isLoading {
                        ProgressView("Loading destinations…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        destinationPicker
                        echoMode
                        publishButton
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("echo-error")
                    }
                    if let successMessage {
                        Text(successMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("echo-success")
                    }
                }
                .padding(16)
            }
            .background(C.bg)
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .task { await loadDestinations() }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Echo preview")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(C.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Divider().overlay(C.borderSubtle)

            HStack(spacing: 12) {
                previewArtwork

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.eyebrow)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(C.watch)
                    Text(content.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.text.opacity(0.92))
                        .lineLimit(2)
                    if let description = content.description,
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                            .lineLimit(2)
                    }
                    if let source = content.sourceName ?? content.subtitle {
                        Text(source)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(C.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 96)
            .padding(12)
        }
        .background(C.surface.opacity(0.72))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Content being Echoed")
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
        if let personal = destinations.first(where: \.isPersonal) {
            destinationRow(personal, subtitle: "Echo directly to My Pulse")
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Find a Vibe")
                .font(.caption.bold())
                .foregroundStyle(C.textMuted)
            TextField("Search by Vibe name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Vibes appear after you start typing.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if matchingVibes.isEmpty {
                Text("No matching Vibes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(matchingVibes) { vibe in
                    destinationRow(vibe, subtitle: nil)
                }
            }
        }

        if !selectedSlugs.isEmpty {
            HStack {
                Text("\(selectedSlugs.count) destination\(selectedSlugs.count == 1 ? "" : "s") selected")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Clear") { selectedSlugs.removeAll() }
                    .font(.caption.bold())
            }
            .foregroundStyle(C.watch)
        }
    }

    private var echoMode: some View {
        VStack(spacing: 10) {
            Picker("Echo mode", selection: $isQuoteEcho) {
                Text("Echo").tag(false)
                Text("Quote Echo").tag(true)
            }
            .pickerStyle(.segmented)

            if isQuoteEcho {
                TextField("Add your take…", text: $quote, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var publishButton: some View {
        Button {
            Task { await publish() }
        } label: {
            Label(
                isPublishing
                    ? "Echoing…"
                    : "Echo\(selectedSlugs.count > 1 ? " to \(selectedSlugs.count)" : "")",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(C.watch)
        .disabled(selectedSlugs.isEmpty || isPublishing)
    }

    private var matchingVibes: [PostableVibe] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return destinations.filter {
            !$0.isPersonal && "\($0.name) \($0.slug)".lowercased().contains(normalized)
        }
    }

    private func destinationRow(_ vibe: PostableVibe, subtitle: String?) -> some View {
        Button {
            if selectedSlugs.contains(vibe.slug) {
                selectedSlugs.remove(vibe.slug)
            } else {
                selectedSlugs.insert(vibe.slug)
            }
            errorMessage = nil
            successMessage = nil
        } label: {
            HStack(spacing: 10) {
                SocialIdentityAvatar(image: vibe.avatarURL, name: vibe.name, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.isPersonal ? "My Pulse" : vibe.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                Image(systemName: selectedSlugs.contains(vibe.slug) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selectedSlugs.contains(vibe.slug) ? C.watch : C.textMuted)
            }
            .padding(10)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.borderSubtle))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadDestinations() async {
        isLoading = true
        errorMessage = nil
        do {
            _ = try await api.ensurePersonalVibe()
            destinations = try await api.postableVibes()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func publish() async {
        guard !selectedSlugs.isEmpty, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        successMessage = nil
        let slugs = selectedSlugs.sorted()
        var completed = 0
        var pending = 0
        var failures: [String] = []

        await withTaskGroup(of: (String, Result<Ripple, Error>).self) { group in
            for slug in slugs {
                group.addTask {
                    do {
                        let created = try await api.createRipple(
                            inVibe: slug,
                            body: isQuoteEcho ? quote : nil,
                            attachments: [content.attachment]
                        )
                        return (slug, .success(created))
                    } catch {
                        return (slug, .failure(error))
                    }
                }
            }
            for await (slug, result) in group {
                switch result {
                case .success(let created):
                    completed += 1
                    if created.status == "PENDING_REVIEW" { pending += 1 }
                case .failure:
                    failures.append(slug)
                }
            }
        }

        isPublishing = false
        if completed > 0 {
            onEchoed(completed)
            successMessage = pending == completed
                ? "Echo\(completed == 1 ? "" : "es") submitted for moderator review."
                : "Echoed to \(completed) destination\(completed == 1 ? "" : "s")."
        }
        if failures.isEmpty {
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } else {
            selectedSlugs = Set(failures)
            errorMessage = "Could not Echo to \(failures.joined(separator: ", "))."
        }
    }
}
