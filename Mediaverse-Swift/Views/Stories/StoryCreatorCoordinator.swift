import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private enum StoryCreatorStep: Int {
    case publisher
    case media
    case editor
    case metadata
    case publish
    case success
}

private enum StoryPublishPhase: String {
    case idle
    case rendering = "Rendering..."
    case preparingUpload = "Preparing upload..."
    case uploading = "Uploading..."
    case publishing = "Publishing..."
    case complete = "Story posted!"
}

private enum StoryDraftMedia {
    case image(data: Data, preview: UIImage)
    case video(url: URL, duration: Int)

    var mediaType: String {
        switch self {
        case .image: return "image"
        case .video: return "video"
        }
    }

    var mimeType: String {
        switch self {
        case .image: return "image/jpeg"
        case .video(let url, _): return StoryDraftMedia.videoMimeType(for: url)
        }
    }

    var duration: Int {
        switch self {
        case .image: return 5
        case .video(_, let duration): return duration
        }
    }

    func uploadData() throws -> Data {
        switch self {
        case .image(let data, _):
            return data
        case .video(let url, _):
            return try Data(contentsOf: url)
        }
    }

    private static func videoMimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension), let mimeType = type.preferredMIMEType else {
            return "video/mp4"
        }
        return mimeType
    }
}

struct StoryCreatorCoordinator: View {
    let preselectedPublisher: UploadContext?
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: StoryCreatorStep = .media
    @State private var contexts: UploadContextsResponse?
    @State private var selectedPublisher: UploadContext?
    @State private var isLoadingPublishers = true
    @State private var errorText: String?

    @State private var isCameraPresented = true
    @State private var isShowingPostDrawer = false
    @State private var draftMedia: StoryDraftMedia?
    @State private var currentProject: Project?
    @State private var isPreparingMedia = false

    @State private var caption = ""
    @State private var ctaLabel = ""
    @State private var ctaUrl = ""
    @State private var destinationSearch = ""

    @State private var publishPhase: StoryPublishPhase = .idle
    @State private var publishProgress = 0.0
    @State private var publishTask: Task<Void, Never>?
    @State private var createdStory: StoryItem?
    private let exportService = StoryExportService()

    private var publishers: [UploadContext] {
        (contexts?.channels ?? []) + (contexts?.shows ?? [])
    }

    private var resolvedPublisher: UploadContext? {
        selectedPublisher ?? (publishers.count == 1 ? publishers.first : nil)
    }

    private var filteredPublishers: [UploadContext] {
        let query = destinationSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = publishers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else {
            return []
        }
        return Array(source.filter { publisher in
            publisher.name.lowercased().contains(query)
            || (publisher.networkName ?? "").lowercased().contains(query)
            || publisher.type.lowercased().contains(query)
        }.prefix(12))
    }

    private var canPostStory: Bool {
        guard draftMedia != nil, currentProject != nil, resolvedPublisher != nil else { return false }
        let trimmedLabel = ctaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = ctaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty && trimmedURL.isEmpty { return true }
        return !trimmedLabel.isEmpty && validCTAURL(trimmedURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(step == .editor || step == .media ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        if step == .publish {
                            cancelPublish()
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(C.text)
                }
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            StoryCameraView(maxDuration: storyMaxDurationSeconds) {
                handleCameraCancel()
            } onPhoto: { data, image in
                isCameraPresented = false
                Task { await importCameraPhoto(data: data, image: image) }
            } onLibraryVideo: { url in
                isCameraPresented = false
                Task { await importLibraryVideo(url) }
            } onComplete: { segments in
                isCameraPresented = false
                Task { await importCameraSegments(segments) }
            }
        }
        .sheet(isPresented: $isShowingPostDrawer) {
            postDrawer
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if draftMedia == nil {
                step = .media
                isCameraPresented = true
            }
        }
        .task { await loadPublishers() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .editor:
            editorStep
        case .media:
            cameraLaunchStep
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let errorText {
                        errorBanner(errorText)
                    }

                    switch step {
                    case .publisher:
                        publisherStep
                    case .media:
                        EmptyView()
                    case .editor:
                        EmptyView()
                    case .metadata:
                        metadataStep
                    case .publish:
                        publishStep
                    case .success:
                        successStep
                    }
                }
                .padding(C.pagePad)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(headerTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(C.text)
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(C.textMuted)
        }
    }

    private var headerTitle: String {
        switch step {
        case .publisher: return "Choose publisher"
        case .media: return "Story camera"
        case .editor: return "Edit story"
        case .metadata: return "Story details"
        case .publish: return "Posting story"
        case .success: return "Story posted"
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .publisher: return "Stories attach to a channel or show you manage."
        case .media: return "Use a portrait photo or a portrait video up to 60 seconds."
        case .editor: return "Preview the saved draft with the same compositor used for export."
        case .metadata: return "Add the viewer-facing caption and optional action."
        case .publish: return "The app uploads directly to the platform-provided destination."
        case .success: return "It will expire automatically in 24 hours."
        }
    }

    private var publisherStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingPublishers {
                loadingRow("Loading publishers...")
            } else if publishers.isEmpty {
                Text("You need a channel or managed show before posting a story.")
                    .font(.system(size: 13))
                    .foregroundStyle(C.textMuted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(publishers) { publisher in
                    Button {
                        selectedPublisher = publisher
                        openCamera()
                    } label: {
                        publisherRow(publisher, selected: publisher.id == selectedPublisher?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var mediaStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedPublisher {
                publisherSummary(selectedPublisher)
            }

            if let draftMedia {
                mediaPreview(draftMedia)
            }

            mediaSourceButton(icon: "camera", title: "Open Camera", subtitle: "Capture a story or choose existing media from the camera controls") {
                openCamera()
            }
            .accessibilityLabel("Open story camera")

            if draftMedia != nil {
                primaryButton(title: "Open Editor", icon: "slider.horizontal.3") {
                    errorText = nil
                    step = .editor
                }
            }
        }
    }

    private var cameraLaunchStep: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView()
                .tint(C.watch)
        }
    }

    private var editorStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let project = currentProject {
                StoryEditorPreviewView(
                    project: project,
                    onProjectChange: { updatedProject in
                        currentProject = updatedProject
                    },
                    onBack: {
                        step = .media
                        openCamera()
                    },
                    onNext: { isShowingPostDrawer = true }
                )
            } else {
                loadingRow("Preparing editor...")
            }
        }
    }

    private var metadataStep: some View {
        postDrawer
    }

    private var postDrawer: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Share Story")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(C.text)
                        Text("Confirm the destination and add the details viewers will see.")
                            .font(.system(size: 12))
                            .foregroundStyle(C.textMuted)
                    }

                    if let draftMedia {
                        sharePreviewRow(draftMedia)
                    }

                    if publishers.count > 1 {
                        destinationLookup
                    } else if publishers.isEmpty {
                        loadingRow(isLoadingPublishers ? "Loading destinations..." : "No available story destinations.")
                    } else if let publisher = resolvedPublisher {
                        selectedDestinationSummary(publisher)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Caption")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                        TextField("Optional caption", text: $caption, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                            .onChange(of: caption) { _, value in
                                if value.count > 120 { caption = String(value.prefix(120)) }
                            }
                            .storyTextFieldStyle()
                        Text("\(caption.count)/120")
                            .font(.system(size: 10))
                            .foregroundStyle(C.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("CTA")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                        TextField("Label, e.g. Watch Now", text: $ctaLabel)
                            .storyTextFieldStyle()
                        TextField("HTTPS URL or app link", text: $ctaUrl)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .storyTextFieldStyle()
                    }
                }
                .padding(C.pagePad)
                .padding(.bottom, 18)
                }

                Divider()
                    .overlay(C.borderSubtle)

                primaryButton(title: "Share Story", icon: "paperplane.fill") {
                    isShowingPostDrawer = false
                    startPublish()
                }
                .disabled(!canPostStory || publishTask != nil)
                .opacity(canPostStory && publishTask == nil ? 1 : 0.45)
                .padding(C.pagePad)
            }
            .background(C.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isShowingPostDrawer = false }
                        .foregroundStyle(C.text)
                }
            }
        }
    }

    private var destinationLookup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)

            if let selectedPublisher {
                selectedDestinationSummary(selectedPublisher)
            }

            TextField(selectedPublisher == nil ? "Search channel or show" : "Search to change destination", text: $destinationSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .storyTextFieldStyle()

            if destinationSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(selectedPublisher == nil ? "Search for a channel or show to post this story." : "Only the selected destination is shown until you search.")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
            } else if filteredPublishers.isEmpty {
                Text("No matching destinations.")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(filteredPublishers) { publisher in
                    Button {
                        selectedPublisher = publisher
                        destinationSearch = ""
                    } label: {
                        publisherRow(publisher, selected: publisher.id == selectedPublisher?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var publishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: publishProgress)
                .tint(C.watch)
            Text(publishPhase.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(C.text)
            Text("Keep the app open until publishing completes.")
                .font(.system(size: 12))
                .foregroundStyle(C.textTertiary)

            Button(role: .destructive) {
                cancelPublish()
            } label: {
                Label("Cancel Publish", systemImage: "xmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(16)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var successStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(C.watch)
            Text("Story posted! Expires in 24 h.")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(C.text)
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(C.watch)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func publisherRow(_ publisher: UploadContext, selected: Bool) -> some View {
        HStack(spacing: 12) {
            publisherAvatar(publisher)
            VStack(alignment: .leading, spacing: 3) {
                Text(publisher.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text(publisher.networkName ?? (publisher.type == "show" ? "Show" : "Channel"))
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(publisher.type == "show" ? "Show" : "Channel")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(publisher.type == "show" ? C.play : C.watch)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((publisher.type == "show" ? C.play : C.watch).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(C.watch)
            }
        }
        .padding(12)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? C.watch.opacity(0.55) : C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func publisherSummary(_ publisher: UploadContext) -> some View {
        HStack(spacing: 10) {
            publisherAvatar(publisher)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(publisher.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                Text(publisher.type == "show" ? "Show story" : "Channel story")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
            }
            Spacer()
            Button("Change") { step = .publisher }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.watch)
        }
        .padding(12)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func selectedDestinationSummary(_ publisher: UploadContext) -> some View {
        HStack(spacing: 10) {
            publisherAvatar(publisher)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(publisher.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text(publisher.type == "show" ? "Show story" : "Channel story")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(C.watch)
        }
        .padding(12)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.watch.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sharePreviewRow(_ media: StoryDraftMedia) -> some View {
        HStack(spacing: 12) {
            mediaPreview(media)
                .frame(width: 58, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(media.mediaType == "image" ? "Image story" : "Video story")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(C.text)
                Text(media.mediaType == "image" ? "5 seconds" : "\(media.duration) seconds")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(C.textMuted)
                if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func publisherAvatar(_ publisher: UploadContext) -> some View {
        AsyncImage(url: C.mediaURL(publisher.avatarUrl)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    (publisher.type == "show" ? C.play : C.watch).opacity(0.15)
                    Text(String(publisher.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(C.textMuted)
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: publisher.type == "show" ? 7 : 19))
    }

    private func mediaSourceButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .frame(width: 42, height: 42)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(2)
                }
                Spacer()
                if isPreparingMedia {
                    ProgressView().scaleEffect(0.75).tint(C.textMuted)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(C.textTertiary)
                }
            }
            .padding(12)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isPreparingMedia)
    }

    @ViewBuilder
    private func mediaPreview(_ media: StoryDraftMedia) -> some View {
        ZStack(alignment: .bottomLeading) {
            switch media {
            case .image(_, let preview):
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            case .video:
                C.elevated.overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(C.watch)
                        Text("Portrait video")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.text)
                    }
                }
            }

            Text(media.mediaType == "image" ? "Image story" : "Video story · \(media.duration)s")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func primaryButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(C.watch)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8).tint(C.textMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(C.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func openCamera() {
        errorText = nil
        isCameraPresented = true
    }

    private func handleCameraCancel() {
        isCameraPresented = false
        if draftMedia == nil {
            dismiss()
        } else {
            step = .editor
        }
    }

    private func loadPublishers() async {
        isLoadingPublishers = true
        defer { isLoadingPublishers = false }

        do {
            let response = try await APIClient.shared.fetchUploadContexts()
            contexts = response
            if let preselectedPublisher {
                selectedPublisher = preselectedPublisher
            }
            let all = response.channels + response.shows
            if selectedPublisher == nil, all.count == 1, let only = all.first {
                selectedPublisher = only
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }


    private func importCameraPhoto(data: Data, image: UIImage) async {
        isPreparingMedia = true
        defer { isPreparingMedia = false }

        do {
            let normalized = image.storyPortraitNormalized
            let jpegData = normalized.jpegData(compressionQuality: 0.92) ?? data
            currentProject = try await createImageDraft(image: normalized, jpegData: jpegData)
            draftMedia = .image(data: jpegData, preview: normalized)
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importLibraryVideo(_ url: URL) async {
        isPreparingMedia = true
        defer { isPreparingMedia = false }

        do {
            let asset = AVAsset(url: url)
            let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
            guard durationSeconds > 0 else {
                throw StoryCreatorError.message("Could not read the selected video duration.")
            }
            guard durationSeconds <= 60 else {
                throw StoryCreatorError.message("Stories can be up to 60 seconds. Choose or trim a shorter video.")
            }
            let persisted = try await createVideoDraft(sourceURL: url, asset: asset, durationSeconds: durationSeconds)
            currentProject = persisted.project
            draftMedia = .video(url: persisted.mediaURL, duration: max(1, Int(ceil(durationSeconds))))
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importCameraSegments(_ segments: [StoryCapturedSegment]) async {
        guard !segments.isEmpty else { return }
        isPreparingMedia = true
        defer { isPreparingMedia = false }

        do {
            let totalDuration = segments.reduce(0) { $0 + ($1.duration / max($1.speed, 0.5)) }
            guard totalDuration <= storyMaxDurationSeconds + 0.25 else {
                throw StoryCreatorError.message("Stories can be up to 60 seconds. Delete a segment and try again.")
            }
            let assets = segments.map { AVAsset(url: $0.url) }
            let persisted = try await createVideoDraft(segments: Array(zip(segments, assets)))
            currentProject = persisted.project
            draftMedia = .video(url: persisted.mediaURL, duration: max(1, Int(ceil(totalDuration))))
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func isPortraitVideo(_ asset: AVAsset) async throws -> Bool {
        let metrics = try await videoMetrics(asset)
        return metrics.height >= metrics.width
    }

    private func createImageDraft(image: UIImage, jpegData: Data) async throws -> Project {
        var project = Project.storyDraft(
            title: "Story Draft",
            destination: nil
        )
        _ = try await ProjectStore.shared.create(project)
        let store = await ProjectStore.shared.assetStore(for: project.id)
        let relativePath = try store.importData(jpegData, extension: "jpg")
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let assetRef = AssetRef.make(
            kind: .image,
            relativePath: relativePath,
            naturalWidth: pixelWidth,
            naturalHeight: pixelHeight,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        try project.addStoryClip(.storyClip(assetRef: assetRef, durationSeconds: 5))
        try await ProjectStore.shared.save(project)
        return project
    }

    private func createVideoDraft(sourceURL: URL, asset: AVAsset, durationSeconds: Double) async throws -> (project: Project, mediaURL: URL) {
        try await createVideoDraft(segments: [(
            StoryCapturedSegment(
                url: sourceURL,
                duration: durationSeconds,
                speed: 1,
                filterId: nil,
                adjustments: .neutral
            ),
            asset
        )])
    }

    private func createVideoDraft(segments: [(StoryCapturedSegment, AVAsset)]) async throws -> (project: Project, mediaURL: URL) {
        guard let first = segments.first else {
            throw StoryCreatorError.message("Record or choose a video before opening the editor.")
        }

        var project = Project.storyDraft(
            title: first.0.url.deletingPathExtension().lastPathComponent,
            destination: nil
        )
        _ = try await ProjectStore.shared.create(project)
        let store = await ProjectStore.shared.assetStore(for: project.id)
        var firstRelativePath: String?

        for (segment, asset) in segments {
            let pathExtension = segment.url.pathExtension.isEmpty ? "mov" : segment.url.pathExtension
            let relativePath = try store.importFile(segment.url, extension: pathExtension)
            if firstRelativePath == nil { firstRelativePath = relativePath }
            let metrics = try await videoMetrics(asset)
            let durationSeconds = min(segment.duration, (try? await asset.load(.duration).seconds) ?? segment.duration)
            let assetRef = AssetRef.make(
                kind: .video,
                relativePath: relativePath,
                naturalWidth: Int(metrics.width),
                naturalHeight: Int(metrics.height),
                nominalFrameRate: metrics.frameRate,
                durationSeconds: durationSeconds,
                preferredTransform: metrics.transform
            )
            var clip = VideoClip.storyClip(assetRef: assetRef, durationSeconds: durationSeconds)
            clip.speed = min(max(segment.speed, 0.5), 2)
            clip.filterId = segment.filterId
            clip.adjustments = segment.adjustments
            try project.addStoryClip(clip)
        }

        try await ProjectStore.shared.save(project)
        let previewPath = firstRelativePath ?? ""
        return (project, store.absoluteURL(for: previewPath))
    }

    private func videoMetrics(_ asset: AVAsset) async throws -> (width: CGFloat, height: CGFloat, frameRate: Float, transform: CGAffineTransform) {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StoryCreatorError.message("Could not read the selected video track.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        let width = abs(transformed.width) > 0 ? abs(transformed.width) : abs(size.width)
        let height = abs(transformed.height) > 0 ? abs(transformed.height) : abs(size.height)
        let frameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        return (width, height, frameRate, transform)
    }

    private func updateDraftDestination(_ publisher: UploadContext) async throws {
        guard var project = currentProject else { return }
        project.storyDestination = StoryDestination(publisherType: publisher.type, publisherId: publisher.id)
        project.updatedAt = Date()
        try await ProjectStore.shared.save(project)
        currentProject = project
    }

    private func startPublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor in
            await publishStory()
            publishTask = nil
        }
    }

    private func cancelPublish() {
        publishTask?.cancel()
        publishPhase = .idle
        publishProgress = 0
        errorText = "Publishing canceled. No story was created."
        step = .editor
    }

    private func publishStory() async {
        guard let selectedPublisher = resolvedPublisher, draftMedia != nil else { return }
        step = .publish
        publishPhase = .rendering
        publishProgress = 0.05
        errorText = nil

        do {
            try await updateDraftDestination(selectedPublisher)
            guard let project = currentProject else {
                throw StoryCreatorError.message("Story draft is missing. Choose media again.")
            }

            let export = try await exportService.export(project: project) { progress in
                Task { @MainActor in
                    publishProgress = 0.05 + (progress * 0.35)
                }
            }
            try Task.checkCancellation()

            publishPhase = .preparingUpload
            publishProgress = 0.42
            let upload = try await StoriesAPIClient.shared.getUploadUrl(mimeType: export.mimeType)

            try Task.checkCancellation()
            publishPhase = .uploading
            publishProgress = 0.45
            guard let uploadURL = URL(string: upload.uploadUrl) else {
                throw StoriesError.badURL
            }
            let serverMediaUrl = try await StoriesAPIClient.shared.uploadMedia(
                to: uploadURL, fileURL: export.url, mimeType: export.mimeType
            ) { progress in
                Task { @MainActor in
                    publishProgress = 0.45 + (progress * 0.40)
                }
            }
            // serverMediaUrl is non-nil when using the Vercel Blob fallback (directUpload mode).
            // Otherwise fall back to the pre-determined URL from upload-url (R2/CF Stream).
            let finalMediaUrl = serverMediaUrl ?? upload.mediaUrl
            guard !finalMediaUrl.isEmpty else {
                throw StoryCreatorError.message("Upload succeeded but no media URL was returned. Contact support.")
            }
            try Task.checkCancellation()

            publishPhase = .publishing
            publishProgress = 0.90
            let placedLink = firstStoryLink(in: project)
            createdStory = try await StoriesAPIClient.shared.createStory(
                CreateStoryRequest(
                    publisherType: selectedPublisher.type,
                    publisherId: selectedPublisher.id,
                    mediaUrl: finalMediaUrl,
                    mediaType: upload.mediaType,
                    duration: export.duration,
                    caption: nilIfEmpty(caption),
                    ctaLabel: nilIfEmpty(placedLink?.label ?? ctaLabel),
                    ctaUrl: nilIfEmpty(placedLink?.url ?? ctaUrl),
                    expiresInHours: 24
                )
            )
            publishPhase = .complete
            publishProgress = 1
            NotificationCenter.default.post(name: .storiesDidChange, object: nil)
            step = .success
        } catch is CancellationError {
            errorText = "Publishing canceled. No story was created."
            step = .metadata
            publishPhase = .idle
            publishProgress = 0
        } catch StoriesError.notSignedIn {
            errorText = SessionStorage.token == nil
                ? "Your session is missing. Sign in again before posting."
                : "Your story publishing session was rejected by the server. Try again, or refresh your sign-in if it repeats."
            step = .metadata
            publishPhase = .idle
            publishProgress = 0
        } catch StoriesError.serverMessage(let message) {
            errorText = "\(publishFailureContext): \(message)"
            step = .metadata
            publishPhase = .idle
            publishProgress = 0
        } catch let StoriesError.serverUnavailable(statusCode) {
            let suffix = statusCode.map { " HTTP \($0)." } ?? ""
            errorText = "\(publishFailureContext): Stories are temporarily unavailable.\(suffix)"
            step = .metadata
            publishPhase = .idle
            publishProgress = 0
        } catch {
            errorText = "\(publishFailureContext): \(error.localizedDescription)"
            step = .metadata
            publishPhase = .idle
            publishProgress = 0
        }
    }

    private var publishFailureContext: String {
        switch publishPhase {
        case .idle:
            return "Story publish"
        case .rendering:
            return "Rendering story"
        case .preparingUpload:
            return "Preparing upload"
        case .uploading:
            return "Uploading media"
        case .publishing:
            return "Creating story"
        case .complete:
            return "Story publish"
        }
    }

    private func firstStoryLink(in project: Project) -> LinkOverlay? {
        project.tracks.overlays.compactMap { overlay in
            if case .link(let link) = overlay, validCTAURL(link.url) {
                return link
            }
            return nil
        }.first
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validCTAURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "westreem"
    }
}

private enum StoryCreatorError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

extension Notification.Name {
    static let storiesDidChange = Notification.Name("storiesDidChange")
}

private extension View {
    func storyTextFieldStyle() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .foregroundStyle(C.text)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
