import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum RippleComposerDestination: Equatable {
    case personal
    case vibe(slug: String, name: String)
}

struct RippleComposer: View {
    let destination: RippleComposerDestination
    let onCreated: (Ripple) -> Void

    @EnvironmentObject private var auth: AuthManager
    @State private var bodyText = ""
    @State private var isSpoiler = false
    @State private var commentsDisabled = false
    @State private var pollOpen = false
    @State private var pollQuestion = ""
    @State private var pollOptions = ["", "", "", ""]
    @State private var attachment: RippleCreateAttachment?
    @State private var preview: RippleAttachmentPreview?
    @State private var resolvedURL: String?
    @State private var isResolving = false
    @State private var isPublishing = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var photos: [UploadedRipplePhoto] = []
    @State private var isUploadingPhotos = false
    @State private var uploadProgress = 0

    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SocialIdentityAvatar(
                    image: auth.currentUser?.image,
                    name: auth.currentUser?.name,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 6) {
                    TextField(placeholder, text: $bodyText, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.sentences)
                        .padding(11)
                        .background(C.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onChange(of: bodyText) { _, value in
                            resolvePastedLinkIfNeeded(in: value)
                        }
                    MentionAutocompletePanel(text: $bodyText)
                }
            }

            if isResolving || attachment != nil {
                attachmentPreview
            }

            if !photos.isEmpty {
                photoGrid
            }
            if isUploadingPhotos {
                ProgressView(value: Double(uploadProgress), total: 100)
                    .tint(C.watch)
            }

            if pollOpen {
                pollEditor
            }

            HStack(spacing: 4) {
                PhotosPicker(
                    selection: $photoSelections,
                    maxSelectionCount: max(0, 10 - photos.count),
                    matching: .images
                ) {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: photoSelections) { _, items in
                    Task { await upload(items) }
                }
                Button {
                    pollOpen.toggle()
                    if !pollOpen {
                        pollQuestion = ""
                        pollOptions = ["", "", "", ""]
                    }
                } label: {
                    Label(pollOpen ? "Remove Poll" : "Poll", systemImage: "chart.bar")
                }
                optionToggle("Spoiler", systemImage: "eye.slash", isOn: $isSpoiler)
                optionToggle("Close comments", systemImage: "bubble.left.and.exclamationmark", isOn: $commentsDisabled)
                Spacer(minLength: 4)
                Button {
                    Task { await publish() }
                } label: {
                    if isPublishing {
                        ProgressView().tint(.black)
                    } else {
                        Text("Create Ripple")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(!canPublish || isPublishing || isResolving || isUploadingPhotos)
            }
            .font(.caption.weight(.semibold))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if let notice {
                Text(notice).font(.caption.weight(.semibold)).foregroundStyle(C.watch)
            }
        }
        .padding(14)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
    }

    private var placeholder: String {
        switch destination {
        case .personal:
            "Create a Ripple on My Atmo…"
        case .vibe(_, let name):
            "Create a Ripple in \(name)…"
        }
    }

    private var canPublish: Bool {
        let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPoll = pollDraft != nil
        return hasBody || attachment != nil || !photos.isEmpty || hasPoll
    }

    private var pollDraft: RipplePollDraft? {
        guard pollOpen else { return nil }
        let question = pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = pollOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !question.isEmpty, options.count >= 2 else { return nil }
        return RipplePollDraft(question: question, options: Array(options.prefix(10)))
    }

    private var attachmentPreview: some View {
        HStack(spacing: 10) {
            if let url = C.mediaURL(preview?.thumbnailURL) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 72, height: 52)
                ) { $0.resizable().scaledToFill() } placeholder: {
                    C.elevated
                }
                .frame(width: 72, height: 52)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isResolving ? "ellipsis" : "link")
                    .frame(width: 52, height: 52)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isResolving ? "Creating preview…" : preview?.title ?? "Attachment selected")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(preview?.subtitle ?? preview?.kind ?? "")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            if !isResolving {
                Button {
                    attachment = nil
                    preview = nil
                    resolvedURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(C.textMuted)
                .accessibilityLabel("Remove attachment")
            }
        }
        .padding(10)
        .background(C.elevated.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var pollEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Poll").font(.caption.bold()).foregroundStyle(C.textMuted)
            TextField("Poll question", text: $pollQuestion)
            ForEach(pollOptions.indices, id: \.self) { index in
                TextField(
                    "Option \(index + 1)\(index > 1 ? " (optional)" : "")",
                    text: $pollOptions[index]
                )
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(C.elevated.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var photoGrid: some View {
        LazyVGrid(
            columns: photos.count == 1
                ? [GridItem(.flexible())]
                : [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                ZStack(alignment: .topTrailing) {
                    CachedRemoteImage(
                        url: C.mediaURL(photo.imageURL),
                        targetSize: CGSize(width: 260, height: 180)
                    ) { $0.resizable().scaledToFill() } placeholder: {
                        C.elevated
                    }
                    .frame(height: photos.count == 1 ? 190 : 120)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button {
                        photos.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.7), in: Circle())
                    }
                    .padding(6)
                    .accessibilityLabel("Remove photo")
                }
            }
        }
    }

    private func optionToggle(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(isOn.wrappedValue ? C.watch : C.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(isOn.wrappedValue ? C.watch.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func resolvePastedLinkIfNeeded(in value: String) {
        guard attachment == nil, !isResolving,
              let url = firstHTTPURL(in: value),
              resolvedURL != url
        else { return }
        resolvedURL = url
        isResolving = true
        errorMessage = nil
        Task {
            do {
                let result = try await api.resolveAttachment(url: url)
                await MainActor.run {
                    attachment = result.attachment.createAttachment
                    preview = result.preview
                    if value.trimmingCharacters(in: .whitespacesAndNewlines) == url {
                        bodyText = ""
                    }
                    isResolving = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isResolving = false
                }
            }
        }
    }

    @MainActor
    private func upload(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, !isUploadingPhotos else { return }
        isUploadingPhotos = true
        errorMessage = nil
        defer {
            isUploadingPhotos = false
            uploadProgress = 0
            photoSelections = []
        }
        do {
            let slug: String
            switch destination {
            case .personal:
                slug = try await api.ensurePersonalVibe().slug
            case .vibe(let destinationSlug, _):
                slug = destinationSlug
            }
            let available = Array(items.prefix(max(0, 10 - photos.count)))
            for (index, item) in available.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LegacySocialAPIError.invalidPhoto
                }
                let contentType = item.supportedContentTypes.first ?? .jpeg
                let mimeType = contentType.preferredMIMEType ?? "image/jpeg"
                let photo = try await api.uploadRipplePhoto(
                    toVibe: slug,
                    data: data,
                    mimeType: mimeType
                )
                photos.append(photo)
                uploadProgress = Int((Double(index + 1) / Double(available.count)) * 100)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func publish() async {
        guard canPublish, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        notice = nil
        do {
            let slug: String
            switch destination {
            case .personal:
                slug = try await api.ensurePersonalVibe().slug
            case .vibe(let destinationSlug, _):
                slug = destinationSlug
            }
            let created = try await api.createRipple(
                inVibe: slug,
                body: bodyText,
                attachments: photos.map { .photo(imageURL: $0.imageURL) }
                    + (attachment.map { [$0] } ?? []),
                poll: pollDraft,
                isSpoiler: isSpoiler,
                commentsDisabled: commentsDisabled
            )
            reset()
            notice = created.status == "PENDING_REVIEW"
                ? "Ripple submitted for moderator review."
                : "Ripple published."
            onCreated(created)
        } catch {
            errorMessage = error.localizedDescription
        }
        isPublishing = false
    }

    private func reset() {
        bodyText = ""
        isSpoiler = false
        commentsDisabled = false
        pollOpen = false
        pollQuestion = ""
        pollOptions = ["", "", "", ""]
        attachment = nil
        preview = nil
        resolvedURL = nil
        photoSelections = []
        photos = []
    }
}

private func firstHTTPURL(in text: String) -> String? {
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    return detector.matches(in: text, range: range)
        .first(where: { $0.url?.scheme == "https" || $0.url?.scheme == "http" })?
        .url?
        .absoluteString
}
