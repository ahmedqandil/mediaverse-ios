import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum RippleComposerDestination: Equatable {
    case personal
    case vibe(slug: String, name: String)
    case wave(vibeSlug: String, vibeName: String, wave: VibeWave)
}

private struct RipplePhotoPositioning: Identifiable {
    let index: Int
    let photo: UploadedRipplePhoto
    let image: UIImage
    var id: String { photo.imageURL }
}

struct RippleComposer: View {
    let destination: RippleComposerDestination
    let onCreated: (Ripple) -> Void

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var bodyText = ""
    @State private var isSpoiler = false
    @State private var commentsDisabled = false
    @State private var resourceCategory = ""
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
    @State private var showsPhotoSourceChooser = false
    @State private var showsPhotoLibrary = false
    @State private var showsCamera = false
    @State private var photos: [UploadedRipplePhoto] = []
    @State private var photoSourceImages: [String: UIImage] = [:]
    @State private var positioningPhoto: RipplePhotoPositioning?
    @State private var isUploadingPhotos = false
    @State private var uploadProgress = 0
    @FocusState private var isBodyFocused: Bool

    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SocialIdentityAvatar(
                    image: auth.currentUser?.image,
                    name: auth.currentUser?.name,
                    size: 42
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.currentUser?.name ?? "Your Atmo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Label(destinationLabel, systemImage: destinationIcon)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                if isUploadingPhotos {
                    ProgressView()
                        .tint(C.watch)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField(placeholder, text: $bodyText, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($isBodyFocused)
                    .textInputAutocapitalization(.sentences)
                    .foregroundStyle(C.text)
                    .tint(C.watch)
                    .font(.body)
                    .frame(minHeight: isCompactWidth ? 112 : 132, alignment: .topLeading)
                    .onChange(of: bodyText) { _, value in
                        resolvePastedLinkIfNeeded(in: value)
                    }
                MentionAutocompletePanel(text: $bodyText)
                    .zIndex(20)
            }
            .padding(12)
            .background(C.elevated.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isBodyFocused ? C.watch.opacity(0.75) : C.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .zIndex(10)

            if isResourceWave {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Resource category", systemImage: "bookmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(C.textMuted)
                    TextField("Guide, Tool, Reference…", text: $resourceCategory)
                        .textInputAutocapitalization(.words)
                        .westreemField()
                    Text("A Resource needs both a category and a pasted link.")
                        .font(.caption2)
                        .foregroundStyle(C.textTertiary)
                }
            }

            if isResolving || attachment != nil {
                attachmentPreview
            }

            if !photos.isEmpty {
                photoGrid
            }
            if isUploadingPhotos {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preparing and uploading photos")
                        Spacer()
                        Text("\(uploadProgress)%")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    ProgressView(value: Double(uploadProgress), total: 100)
                        .tint(C.watch)
                }
            }

            if pollOpen {
                pollEditor
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Add to your Ripple")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)

                HStack(spacing: 10) {
                Button {
                    isBodyFocused = false
                    showsPhotoSourceChooser = true
                } label: {
                    composerToolLabel(
                        "Photo",
                        systemImage: "photo.on.rectangle.angled",
                        selected: !photos.isEmpty
                    )
                }
                .buttonStyle(.plain)
                .disabled(isUploadingPhotos || photos.count >= 10)
                Button {
                    pollOpen.toggle()
                    if !pollOpen {
                        pollQuestion = ""
                        pollOptions = ["", "", "", ""]
                    }
                } label: {
                    composerToolLabel(
                        "Poll",
                        systemImage: "chart.bar",
                        selected: pollOpen
                    )
                }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Post options")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                HStack(spacing: 8) {
                    optionToggle("Spoiler", systemImage: "eye.slash", isOn: $isSpoiler)
                    optionToggle(
                        "Comments off",
                        systemImage: "bubble.left.and.exclamationmark",
                        isOn: $commentsDisabled
                    )
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.watch)
            }

            Button {
                isBodyFocused = false
                Task { await publish() }
            } label: {
                HStack {
                    Spacer()
                    if isPublishing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "wave.3.right")
                        Text("Publish Ripple")
                    }
                    Spacer()
                }
                .font(.headline)
                .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
            .disabled(!canPublish || isPublishing || isResolving || isUploadingPhotos)
        }
        .padding(isCompactWidth ? 14 : 18)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: C.cardRadius).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
        .confirmationDialog(
            "Add a photo",
            isPresented: $showsPhotoSourceChooser,
            titleVisibility: .visible
        ) {
            Button("Take Photo") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showsCamera = true
                } else {
                    errorMessage = "The camera is not available on this device."
                }
            }
            Button("Choose from Library") {
                showsPhotoLibrary = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showsPhotoLibrary,
            selection: $photoSelections,
            maxSelectionCount: max(0, 10 - photos.count),
            matching: .images
        )
        .onChange(of: photoSelections) { _, items in
            Task { await upload(items) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            RipplePhotoCameraPicker(
                onCapture: { image in
                    showsCamera = false
                    Task { await uploadCapturedPhoto(image) }
                },
                onCancel: { showsCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func composerToolLabel(
        _ title: String,
        systemImage: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(selected ? C.watch : C.text)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(selected ? C.watch.opacity(0.13) : C.elevated)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? C.watch.opacity(0.55) : C.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var destinationLabel: String {
        switch destination {
        case .personal:
            "Posting to My Atmo"
        case .vibe(_, let name):
            "Posting to \(name)"
        case .wave(_, let vibeName, let wave):
            "Posting to \(vibeName) · \(wave.name)"
        }
    }

    private var destinationIcon: String {
        switch destination {
        case .personal: "person.crop.circle"
        case .vibe: "person.3"
        case .wave: "wave.3.right"
        }
    }

    private var placeholder: String {
        switch destination {
        case .personal:
            "Create a Ripple on My Atmo…"
        case .vibe(_, let name):
            "Create a Ripple in \(name)…"
        case .wave(_, _, let wave):
            "Create a Ripple in \(wave.name)…"
        }
    }

    private var canPublish: Bool {
        let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPoll = pollDraft != nil
        let hasContent = hasBody || attachment != nil || !photos.isEmpty || hasPoll
        if isResourceWave {
            return hasContent && SpecializedWaveUIRules.canPublishResource(
                category: resourceCategory,
                hasAttachment: attachment != nil
            )
        }
        return hasContent
    }

    private var isResourceWave: Bool {
        if case .wave(_, _, let wave) = destination { return wave.type == .resources }
        return false
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Poll", systemImage: "chart.bar.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(C.text)
                Spacer()
                Button {
                    pollOpen = false
                    pollQuestion = ""
                    pollOptions = ["", "", "", ""]
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(C.textMuted)
                }
                .accessibilityLabel("Remove poll")
            }
            TextField("Ask a question", text: $pollQuestion)
                .font(.body.weight(.semibold))
                .foregroundStyle(C.text)
            ForEach(pollOptions.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(C.textMuted)
                        .frame(width: 22, height: 22)
                        .background(C.surface, in: Circle())
                    TextField(
                        "Option \(index + 1)\(index > 1 ? " (optional)" : "")",
                        text: $pollOptions[index]
                    )
                    .foregroundStyle(C.text)
                }
            }
        }
        .textFieldStyle(.plain)
        .tint(C.watch)
        .padding(12)
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

                    HStack(spacing: 6) {
                        if let source = photoSourceImages[photo.imageURL] {
                            Button {
                                positioningPhoto = RipplePhotoPositioning(
                                    index: index,
                                    photo: photo,
                                    image: source
                                )
                            } label: {
                                Image(systemName: "crop")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(.black.opacity(0.7), in: Circle())
                            }
                            .accessibilityLabel("Adjust photo position")
                        }

                        Button {
                            photoSourceImages.removeValue(forKey: photo.imageURL)
                            photos.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.7), in: Circle())
                        }
                        .accessibilityLabel("Remove photo")
                    }
                    .padding(6)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn.wrappedValue ? C.watch : C.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(isOn.wrappedValue ? C.watch.opacity(0.12) : C.elevated)
                .overlay(
                    Capsule()
                        .stroke(isOn.wrappedValue ? C.watch.opacity(0.5) : C.borderSubtle)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fullScreenCover(item: $positioningPhoto) { pending in
            WestreemImagePositionEditor(
                image: pending.image,
                aspectRatio: 1,
                title: "Position Photo",
                onCancel: { positioningPhoto = nil },
                onApply: { positioned in
                    positioningPhoto = nil
                    Task { await replacePositionedPhoto(pending, with: positioned) }
                }
            )
        }
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
            let slug = try await uploadVibeSlug()
            let available = Array(items.prefix(max(0, 10 - photos.count)))
            for (index, item) in available.enumerated() {
                guard let originalData = try await item.loadTransferable(type: Data.self),
                      let sourceImage = UIImage(data: originalData),
                      let data = preparedPhotoData(from: originalData)
                else {
                    throw LegacySocialAPIError.invalidPhoto
                }
                let photo = try await api.uploadRipplePhoto(
                    toVibe: slug,
                    data: data,
                    mimeType: "image/jpeg"
                )
                photos.append(photo)
                photoSourceImages[photo.imageURL] = sourceImage
                uploadProgress = Int((Double(index + 1) / Double(available.count)) * 100)
            }
        } catch {
            if case APIError.http(413) = error {
                errorMessage = "This photo is still too large to upload. Try a smaller image."
            } else {
                errorMessage = socialErrorMessage(error)
            }
        }
    }

    @MainActor
    private func replacePositionedPhoto(
        _ pending: RipplePhotoPositioning,
        with image: UIImage
    ) async {
        guard photos.indices.contains(pending.index),
              photos[pending.index].imageURL == pending.photo.imageURL else { return }
        isUploadingPhotos = true
        errorMessage = nil
        defer {
            isUploadingPhotos = false
            uploadProgress = 0
        }
        do {
            guard let originalData = image.jpegData(compressionQuality: 0.92),
                  let data = preparedPhotoData(from: originalData) else {
                throw LegacySocialAPIError.invalidPhoto
            }
            let replacement = try await api.uploadRipplePhoto(
                toVibe: try await uploadVibeSlug(),
                data: data,
                mimeType: "image/jpeg"
            )
            photoSourceImages.removeValue(forKey: pending.photo.imageURL)
            photoSourceImages[replacement.imageURL] = image
            photos[pending.index] = replacement
            uploadProgress = 100
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    @MainActor
    private func uploadCapturedPhoto(_ image: UIImage) async {
        guard !isUploadingPhotos, photos.count < 10 else { return }
        isUploadingPhotos = true
        uploadProgress = 5
        errorMessage = nil
        defer {
            isUploadingPhotos = false
            uploadProgress = 0
        }
        do {
            guard let originalData = image.jpegData(compressionQuality: 0.94),
                  let data = preparedPhotoData(from: originalData) else {
                throw LegacySocialAPIError.invalidPhoto
            }
            uploadProgress = 35
            let photo = try await api.uploadRipplePhoto(
                toVibe: try await uploadVibeSlug(),
                data: data,
                mimeType: "image/jpeg"
            )
            photos.append(photo)
            photoSourceImages[photo.imageURL] = image
            uploadProgress = 100
        } catch {
            if case APIError.http(413) = error {
                errorMessage = "This photo is still too large to upload. Try again."
            } else {
                errorMessage = socialErrorMessage(error)
            }
        }
    }

    private func uploadVibeSlug() async throws -> String {
        switch destination {
        case .personal:
            return try await api.ensurePersonalVibe().slug
        case .vibe(let slug, _):
            return slug
        case .wave(let vibeSlug, _, _):
            return vibeSlug
        }
    }

    /// Keeps the existing R2 upload contract while staying below the web proxy's
    /// request-body ceiling. Rendering also normalizes camera orientation and HEIC.
    private func preparedPhotoData(from originalData: Data) -> Data? {
        guard let source = UIImage(data: originalData) else { return nil }
        let maxBytes = 3_750_000
        var maxPixel: CGFloat = 2048
        var quality: CGFloat = 0.84

        for _ in 0..<6 {
            let largestSide = max(source.size.width, source.size.height)
            let scale = largestSide > maxPixel ? maxPixel / largestSide : 1
            let targetSize = CGSize(
                width: max(1, floor(source.size.width * scale)),
                height: max(1, floor(source.size.height * scale))
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                UIColor.black.setFill()
                UIRectFill(CGRect(origin: .zero, size: targetSize))
                source.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
            quality = max(0.58, quality - 0.07)
            maxPixel *= 0.82
        }
        return nil
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
            case .wave(let vibeSlug, _, _):
                slug = vibeSlug
            }
            let waveId: String?
            if case .wave(_, _, let wave) = destination {
                waveId = wave.id
            } else {
                waveId = nil
            }
            let created = try await api.createRipple(
                inVibe: slug,
                body: bodyText,
                attachments: photos.map { .photo(imageURL: $0.imageURL) }
                    + (attachment.map { [$0] } ?? []),
                poll: pollDraft,
                isSpoiler: isSpoiler,
                commentsDisabled: commentsDisabled,
                waveId: waveId,
                resourceCategory: isResourceWave ? resourceCategory : nil
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
        resourceCategory = ""
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

private struct RipplePhotoCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
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
