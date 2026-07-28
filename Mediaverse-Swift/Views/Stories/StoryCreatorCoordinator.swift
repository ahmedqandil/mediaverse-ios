import AVFoundation
import CoreImage
import SwiftUI
import UserNotifications
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
    case processing = "Processing video..."
    case complete = "Flash posted!"
}

private enum StoryDraftMedia {
    case image(data: Data, preview: UIImage)
    case video(url: URL, duration: Int, thumbnail: UIImage?)

    var mediaType: String {
        switch self {
        case .image: return "image"
        case .video: return "video"
        }
    }

    var mimeType: String {
        switch self {
        case .image: return "image/jpeg"
        case .video(let url, _, _): return StoryDraftMedia.videoMimeType(for: url)
        }
    }

    var duration: Int {
        switch self {
        case .image: return Int(storyMaxDurationSeconds)
        case .video(_, let duration, _): return duration
        }
    }

    var previewImage: UIImage? {
        switch self {
        case .image(_, let preview):
            return preview
        case .video(_, _, let thumbnail):
            return thumbnail
        }
    }

    func uploadData() throws -> Data {
        switch self {
        case .image(let data, _):
            return data
        case .video(let url, _, _):
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

    init(preselectedPublisher: UploadContext?, onComplete: @escaping () -> Void) {
        self.preselectedPublisher = preselectedPublisher
        self.onComplete = onComplete
        _selectedPublisher = State(initialValue: preselectedPublisher)
        _isCameraPresented = State(initialValue: preselectedPublisher != nil)
        _shouldDismissOnCameraCancel = State(initialValue: preselectedPublisher != nil)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: StoryCreatorStep = .media
    @State private var contexts: UploadContextsResponse?
    @State private var selectedPublisher: UploadContext?
    @State private var isLoadingPublishers = true
    @State private var errorText: String?

    @State private var isCameraPresented = false
    @State private var shouldDismissOnCameraCancel = false
    @State private var isShowingPostDrawer = false
    @State private var isShowingEditorExitConfirmation = false
    @State private var draftMedia: StoryDraftMedia?
    @State private var currentProject: Project?
    @State private var savedDrafts: [Project] = []
    @State private var savedDraftThumbnails: [UUID: UIImage] = [:]
    @State private var isLoadingDrafts = true
    @State private var isShowingClearDraftsConfirmation = false
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
        selectedPublisher ?? preselectedPublisher ?? (publishers.count == 1 ? publishers.first : nil)
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
                if isCameraPresented {
                    camera
                } else {
                    C.bg.ignoresSafeArea()
                    content
                }
            }
            .navigationTitle("Flash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isCameraPresented || step == .editor || step == .media ? .hidden : .visible, for: .navigationBar)
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
        .sheet(isPresented: $isShowingPostDrawer) {
            postDrawerSheet
        }
        .confirmationDialog(
            "Leave this flash?",
            isPresented: $isShowingEditorExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save Draft") {
                dismiss()
            }
            Button("Discard Flash", role: .destructive) {
                discardCurrentDraft()
            }
            Button("Continue Editing", role: .cancel) {}
        } message: {
            Text("Your changes are saved automatically. You can keep the draft or discard it permanently.")
        }
        .confirmationDialog(
            "Clear all drafts?",
            isPresented: $isShowingClearDraftsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Drafts", role: .destructive) {
                Task { await clearAllSavedDrafts() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved flash draft and its local media.")
        }
        .task {
            await loadPublishers()
            await loadSavedDrafts()
        }
    }

    private var camera: some View {
        StoryCameraView(maxDuration: storyMaxDurationSeconds) {
            handleCameraCancel()
        } onPhoto: { photo in
            shouldDismissOnCameraCancel = false
            isCameraPresented = false
            Task { await importCameraPhoto(photo) }
        } onLibraryVideo: { url in
            shouldDismissOnCameraCancel = false
            isCameraPresented = false
            Task { await importLibraryVideo(url) }
        } onComplete: { segments in
            shouldDismissOnCameraCancel = false
            isCameraPresented = false
            Task { await importCameraSegments(segments) }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .editor:
            editorStep
        case .media:
            if isPreparingMedia {
                cameraLaunchStep
            } else {
                mediaRecoveryStep
            }
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
        case .media: return "Flash camera"
        case .editor: return "Edit flash"
        case .metadata: return "Flash details"
        case .publish: return "Posting flash"
        case .success: return "Flash posted"
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .publisher: return "Flashes attach to a channel or show you manage."
        case .media: return "Use a portrait photo or a portrait video up to 10 seconds."
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
                Text("You need a channel or managed show before posting a flash.")
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
            if let resolvedPublisher {
                publisherSummary(resolvedPublisher)
            }

            if let draftMedia {
                mediaPreview(draftMedia)
            }

            if currentProject == nil {
                savedDraftSection
            }

            mediaSourceButton(icon: "camera", title: "Open Camera", subtitle: "Capture a flash or choose existing media from the camera controls") {
                openCamera()
            }
            .accessibilityLabel("Open flash camera")

            if draftMedia != nil {
                primaryButton(title: "Open Editor", icon: "slider.horizontal.3") {
                    errorText = nil
                    step = .editor
                }
            }
        }
    }

    @ViewBuilder
    private var savedDraftSection: some View {
        if isLoadingDrafts {
            loadingRow("Loading drafts...")
        } else if !savedDrafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Drafts")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.text)
                    Spacer()
                    Button("Clear All", role: .destructive) {
                        isShowingClearDraftsConfirmation = true
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Clear all flash drafts")
                }

                ForEach(savedDrafts) { draft in
                    HStack(spacing: 10) {
                        Button {
                            Task { await resumeSavedDraft(draft) }
                        } label: {
                            HStack(spacing: 11) {
                                draftThumbnail(for: draft)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Flash draft")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(C.text)
                                    Text("\(Int(ceil(draft.totalDurationSeconds)))s · Edited \(draft.updatedAt, style: .relative)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(C.textTertiary)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(C.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            Task { await deleteSavedDraft(draft) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete flash draft")
                    }
                    .padding(10)
                    .background(C.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @MainActor
    private func loadSavedDrafts() async {
        isLoadingDrafts = true
        defer { isLoadingDrafts = false }
        do {
            savedDrafts = try await ProjectStore.shared.list()
                .filter { !$0.tracks.videoClips.isEmpty }
            await loadSavedDraftThumbnails(for: savedDrafts)
        } catch {
            savedDrafts = []
            savedDraftThumbnails = [:]
            errorText = "Could not load saved flash drafts."
        }
    }

    @ViewBuilder
    private func draftThumbnail(for draft: Project) -> some View {
        ZStack {
            if let thumbnail = savedDraftThumbnails[draft.id] {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                C.elevated
                Image(systemName: draft.tracks.videoClips.first?.assetRef.kind == .video
                    ? "play.rectangle.fill"
                    : "photo.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(C.watch)
            }

            if draft.tracks.videoClips.first?.assetRef.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.58))
                    .clipShape(Circle())
            }
        }
        .frame(width: 48, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipped()
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadSavedDraftThumbnails(for drafts: [Project]) async {
        var thumbnails: [UUID: UIImage] = [:]
        for draft in drafts {
            guard let clip = draft.tracks.videoClips.first else { continue }
            let store = await ProjectStore.shared.assetStore(for: draft.id)
            let url = store.absoluteURL(for: clip.assetRef.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            switch clip.assetRef.kind {
            case .image:
                if let image = UIImage(contentsOfFile: url.path) {
                    thumbnails[draft.id] = image
                }
            case .video:
                if let image = await makeVideoThumbnail(url: url) {
                    thumbnails[draft.id] = image
                }
            case .audio:
                break
            }
        }
        savedDraftThumbnails = thumbnails
    }

    @MainActor
    private func resumeSavedDraft(_ draft: Project) async {
        guard let clip = draft.tracks.videoClips.first else { return }
        isPreparingMedia = true
        errorText = nil
        defer { isPreparingMedia = false }

        let store = await ProjectStore.shared.assetStore(for: draft.id)
        let mediaURL = store.absoluteURL(for: clip.assetRef.relativePath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            errorText = "This draft’s original media is missing."
            return
        }

        switch clip.assetRef.kind {
        case .image:
            guard let data = try? Data(contentsOf: mediaURL),
                  let preview = UIImage(data: data) else {
                errorText = "Could not open this image draft."
                return
            }
            draftMedia = .image(data: data, preview: preview)
        case .video:
            let thumbnail = await makeVideoThumbnail(url: mediaURL)
            draftMedia = .video(
                url: mediaURL,
                duration: max(1, Int(ceil(draft.totalDurationSeconds))),
                thumbnail: thumbnail
            )
        case .audio:
            errorText = "This draft does not contain visual media."
            return
        }

        currentProject = draft
        step = .editor
    }

    @MainActor
    private func deleteSavedDraft(_ draft: Project) async {
        do {
            try await ProjectStore.shared.delete(id: draft.id)
            savedDrafts.removeAll { $0.id == draft.id }
            savedDraftThumbnails[draft.id] = nil
        } catch {
            errorText = "Could not delete this flash draft."
        }
    }

    @MainActor
    private func clearAllSavedDrafts() async {
        let drafts = savedDrafts
        var failedCount = 0
        for draft in drafts {
            do {
                try await ProjectStore.shared.delete(id: draft.id)
                savedDrafts.removeAll { $0.id == draft.id }
                savedDraftThumbnails[draft.id] = nil
            } catch {
                failedCount += 1
            }
        }
        if failedCount > 0 {
            errorText = failedCount == 1
                ? "One flash draft could not be deleted."
                : "\(failedCount) flash drafts could not be deleted."
        }
    }

    private var cameraLaunchStep: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(C.watch)
                Text("Preparing flash...")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private var mediaRecoveryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorText {
                    errorBanner(errorText)
                }
                mediaStep
            }
            .padding(C.pagePad)
            .padding(.bottom, 28)
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
                    onClose: {
                        isShowingEditorExitConfirmation = true
                    },
                    onBack: {
                        step = .media
                        openCamera(dismissOnCancel: true)
                    },
                    onNext: { isShowingPostDrawer = true }
                )
            } else {
                loadingRow("Preparing editor...")
            }
        }
    }

    private func discardCurrentDraft() {
        guard let project = currentProject else {
            dismiss()
            return
        }
        Task {
            try? await ProjectStore.shared.delete(id: project.id)
            await MainActor.run {
                currentProject = nil
                draftMedia = nil
                dismiss()
            }
        }
    }

    private var metadataStep: some View {
        EmptyView()
    }

    private var postDrawerSheet: some View {
        NavigationStack {
            postDrawerContent
                .navigationTitle("Share Flash")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isShowingPostDrawer = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Share") {
                            isShowingPostDrawer = false
                            startPublish()
                        }
                        .disabled(!canPostStory || publishTask != nil)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(C.bg)
    }

    private var postDrawerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose the destination and details viewers will see.")
                    .font(.system(size: 13))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let errorText {
                    errorBanner(errorText)
                }

                if let draftMedia {
                    sharePreviewRow(draftMedia)
                }

                if publishers.count > 1 {
                    destinationLookup
                } else if let publisher = resolvedPublisher {
                    selectedDestinationSummary(publisher)
                } else {
                    loadingRow(isLoadingPublishers ? "Loading destinations..." : "No available flash destinations.")
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
                    MentionAutocompletePanel(text: $caption)
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
            .padding(.bottom, 28)
        }
        .background(C.bg)
    }

    private var destinationLookup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.textMuted)

            if let resolvedPublisher {
                selectedDestinationSummary(resolvedPublisher)
            }

            TextField(resolvedPublisher == nil ? "Search channel or show" : "Search to change destination", text: $destinationSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .storyTextFieldStyle()

            if destinationSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(resolvedPublisher == nil ? "Search for a channel or show to post this flash." : "Only the selected destination is shown until you search.")
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
                        publisherRow(publisher, selected: publisher.id == resolvedPublisher?.id)
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
            Text("You can leave this screen. We'll notify you when the flash is posted.")
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
            Text("Flash posted! Expires in 24 h.")
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
                Text(publisher.type == "show" ? "Show flash" : "Channel flash")
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
                Text(publisher.type == "show" ? "Show flash" : "Channel flash")
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
            Group {
                if let currentProject {
                    StoryFinalSharePreview(project: currentProject, fallbackImage: media.previewImage)
                } else {
                    mediaPreview(media)
                }
            }
                .frame(width: 72, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(media.mediaType == "image" ? "Image flash" : "Video flash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(C.text)
                Text("\(media.duration) seconds")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(C.textMuted)
                Text("Final viewer preview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(C.watch)
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
        CachedRemoteImage(
            url: C.mediaURL(publisher.avatarUrl),
            targetSize: CGSize(width: 38, height: 38)
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                (publisher.type == "show" ? C.play : C.watch).opacity(0.15)
                Text(String(publisher.name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.textMuted)
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
            case .video(_, _, let thumbnail):
                ZStack {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        C.elevated
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(C.watch)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.42))
                            .clipShape(Circle())
                    }
                }
            }

            Text(media.mediaType == "image" ? "Image" : "\(media.duration)s")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(6)
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

    private func openCamera(dismissOnCancel: Bool = false) {
        errorText = nil
        shouldDismissOnCameraCancel = dismissOnCancel
        isCameraPresented = true
    }

    private func handleCameraCancel() {
        isCameraPresented = false
        if shouldDismissOnCameraCancel || draftMedia == nil {
            shouldDismissOnCameraCancel = false
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


    private func importCameraPhoto(_ photo: StoryCapturedPhoto) async {
        isPreparingMedia = true
        defer { isPreparingMedia = false }

        do {
            let normalized = photo.image.storyPortraitNormalized
            let preservesPixels: Bool
            if let source = photo.image.cgImage, let output = normalized.cgImage {
                preservesPixels = source.width == output.width && source.height == output.height
            } else {
                preservesPixels = false
            }
            let jpegData = preservesPixels
                ? photo.data
                : (normalized.jpegData(compressionQuality: 0.98) ?? photo.data)
            currentProject = try await createImageDraft(
                image: normalized,
                jpegData: jpegData,
                filterId: photo.filterId,
                adjustments: photo.adjustments,
                effectStack: photo.effectStack
            )
            let preview = StoryFrameFilterRenderer.renderImage(
                normalized,
                filterId: photo.filterId,
                adjustments: photo.adjustments
            )
            draftMedia = .image(data: preview.jpegData(compressionQuality: 0.96) ?? jpegData, preview: preview)
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
            step = .media
        }
    }

    private func importLibraryVideo(_ url: URL) async {
        isPreparingMedia = true
        defer {
            StoryTemporaryMedia.removeIfOwned(url)
            isPreparingMedia = false
        }

        do {
            let asset = AVAsset(url: url)
            let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
            guard durationSeconds > 0 else {
                throw StoryCreatorError.message("Could not read the selected video duration.")
            }
            guard durationSeconds <= storyMaxDurationSeconds + 0.05 else {
                throw StoryCreatorError.message("Flashes can be up to 10 seconds. Choose or trim a shorter video.")
            }
            let persisted = try await createVideoDraft(sourceURL: url, asset: asset, durationSeconds: durationSeconds)
            let thumbnail = await makeVideoThumbnail(url: persisted.mediaURL)
            currentProject = persisted.project
            draftMedia = .video(url: persisted.mediaURL, duration: max(1, Int(ceil(durationSeconds))), thumbnail: thumbnail)
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
            step = .media
        }
    }

    private func importCameraSegments(_ segments: [StoryCapturedSegment]) async {
        guard !segments.isEmpty else { return }
        isPreparingMedia = true
        defer {
            segments.forEach { StoryTemporaryMedia.removeIfOwned($0.url) }
            isPreparingMedia = false
        }

        do {
            let totalDuration = segments.reduce(0) { $0 + ($1.duration / max($1.speed, 0.5)) }
            guard totalDuration <= storyMaxDurationSeconds + 0.25 else {
                throw StoryCreatorError.message("Flashes can be up to 10 seconds. Delete a segment and try again.")
            }
            let assets = segments.map { AVAsset(url: $0.url) }
            let persisted = try await createVideoDraft(segments: Array(zip(segments, assets)))
            let thumbnail = await makeVideoThumbnail(url: persisted.mediaURL)
            currentProject = persisted.project
            draftMedia = .video(url: persisted.mediaURL, duration: max(1, Int(ceil(totalDuration))), thumbnail: thumbnail)
            errorText = nil
            step = .editor
        } catch {
            errorText = error.localizedDescription
            step = .media
        }
    }

    private func isPortraitVideo(_ asset: AVAsset) async throws -> Bool {
        let metrics = try await videoMetrics(asset)
        return metrics.height >= metrics.width
    }

    private func createImageDraft(
        image: UIImage,
        jpegData: Data,
        filterId: String? = nil,
        adjustments: ColorAdjust = .neutral,
        effectStack: StoryEffectStack? = nil
    ) async throws -> Project {
        var project = Project.storyDraft(
            title: "Flash Draft",
            destination: nil
        )
        _ = try await ProjectStore.shared.create(project)
        do {
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
                durationSeconds: storyMaxDurationSeconds
            )
            var clip = VideoClip.storyClip(assetRef: assetRef, durationSeconds: storyMaxDurationSeconds)
            clip.filterId = filterId
            clip.adjustments = adjustments
            clip.effectStack = effectStack
            try project.addStoryClip(clip)
            try await ProjectStore.shared.save(project)
            return project
        } catch {
            try? await ProjectStore.shared.delete(id: project.id)
            throw error
        }
    }

    private func createVideoDraft(sourceURL: URL, asset: AVAsset, durationSeconds: Double) async throws -> (project: Project, mediaURL: URL) {
        try await createVideoDraft(segments: [(
            StoryCapturedSegment(
                url: sourceURL,
                duration: durationSeconds,
                speed: 1,
                filterId: nil,
                adjustments: .neutral,
                effectStack: nil
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
        do {
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
                clip.effectStack = segment.effectStack
                try project.addStoryClip(clip)
            }

            try await ProjectStore.shared.save(project)
            guard let previewPath = firstRelativePath else {
                throw StoryCreatorError.message("Could not prepare the recorded flash preview.")
            }
            return (project, store.absoluteURL(for: previewPath))
        } catch {
            try? await ProjectStore.shared.delete(id: project.id)
            throw error
        }
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

    private func makeVideoThumbnail(url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 640)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let requested = CMTime(seconds: 0.1, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: requested, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
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
            await queueBackgroundPublish()
            publishTask = nil
        }
    }

    private func queueBackgroundPublish() async {
        guard let selectedPublisher = resolvedPublisher, draftMedia != nil else { return }
        publishPhase = .preparingUpload
        publishProgress = 0
        errorText = nil

        do {
            try await updateDraftDestination(selectedPublisher)
            try Task.checkCancellation()
            let uploadContext = try await ensureStoryUploadContext(for: selectedPublisher)
            try Task.checkCancellation()
            guard let project = currentProject else {
                throw StoryCreatorError.message("Flash draft is missing. Choose media again.")
            }

            let request = StoryBackgroundPublishRequest(
                project: project,
                selectedPublisher: selectedPublisher,
                uploadContext: uploadContext,
                caption: caption,
                ctaLabel: ctaLabel,
                ctaUrl: ctaUrl
            )
            try Task.checkCancellation()
            StoryBackgroundPublisher.shared.enqueue(request)
            dismiss()
        } catch is CancellationError {
            errorText = "Publishing canceled. No flash was created."
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        } catch {
            errorText = error.localizedDescription
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        }
    }

    private func ensureStoryUploadContext(for publisher: UploadContext) async throws -> ActiveContext? {
        guard publisher.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "channel" else {
            return nil
        }
        let context = ActiveContext(
            id: publisher.id,
            type: "channel",
            name: publisher.name,
            channelId: publisher.id,
            damEnabled: nil,
            canCreateShows: nil,
            canPublishMicrodramas: nil
        )
        if let active = SessionStorage.activeContext,
           active.type == context.type,
           active.id == context.id {
            return active
        }
        let response = try await APIClient.shared.switchContext(context)
        guard response.ok else {
            throw StoryCreatorError.message("Could not switch to the selected channel before uploading.")
        }
        return response.context ?? context
    }

    private func cancelPublish() {
        publishTask?.cancel()
        publishPhase = .idle
        publishProgress = 0
        errorText = "Publishing canceled. No flash was created."
        step = .editor
    }

    private func reopenPostDrawerAfterPublishFailure() {
        step = .editor
        isShowingPostDrawer = true
    }

    private func publishStory() async {
        guard let selectedPublisher = resolvedPublisher, draftMedia != nil else { return }
        step = .publish
        publishPhase = .rendering
        publishProgress = 0.05
        errorText = nil

        do {
            try await updateDraftDestination(selectedPublisher)
            _ = try await ensureStoryUploadContext(for: selectedPublisher)
            guard let project = currentProject else {
                throw StoryCreatorError.message("Flash draft is missing. Choose media again.")
            }

            let export = try await exportService.export(project: project) { progress in
                Task { @MainActor in
                    publishProgress = 0.05 + (progress * 0.35)
                }
            }
            if export.isCacheHit {
                publishProgress = 0.40
            }
            try Task.checkCancellation()

            publishPhase = .preparingUpload
            publishProgress = 0.42

            try Task.checkCancellation()
            publishPhase = .uploading
            publishProgress = 0.45
            let uploadedMedia = try await StoryUploadPipeline.upload(export: export) { progress in
                Task { @MainActor in
                    publishProgress = 0.45 + (progress * 0.40)
                }
            }
            try Task.checkCancellation()

            publishPhase = .publishing
            publishProgress = 0.90
            let placedLink = firstStoryLink(in: project)
            let story = try await StoriesAPIClient.shared.createStory(
                CreateStoryRequest(
                    publisherType: selectedPublisher.type,
                    publisherId: selectedPublisher.id,
                    mediaUrl: uploadedMedia.mediaUrl,
                    thumbnailUrl: uploadedMedia.thumbnailUrl,
                    mediaType: uploadedMedia.mediaType,
                    duration: uploadedMedia.duration,
                    caption: storyCaptionPayload(caption: caption, project: project),
                    captionHtml: nil,
                    overlays: storyOverlays(in: project),
                    ctaLabel: nilIfEmpty(placedLink?.label ?? ctaLabel),
                    ctaUrl: nilIfEmpty(placedLink?.url ?? ctaUrl),
                    expiresInHours: 24
                )
            )
            createdStory = story

            if uploadedMedia.mediaType.lowercased().contains("video") {
                publishPhase = .processing
                publishProgress = 0.96
                try await StoryMediaReadiness.waitUntilReady(mediaUrl: uploadedMedia.mediaUrl, mediaType: uploadedMedia.mediaType) { progress in
                    Task { @MainActor in
                        publishProgress = 0.96 + (progress * 0.04)
                    }
                }
            }

            publishPhase = .complete
            publishProgress = 1
            NotificationCenter.default.post(name: .storiesDidChange, object: nil)
            step = .success
        } catch is CancellationError {
            errorText = "Publishing canceled. No flash was created."
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        } catch StoriesError.notSignedIn {
            errorText = SessionStorage.token == nil
                ? "Your session is missing. Sign in again before posting."
                : "Your flash publishing session was rejected by the server. Try again, or refresh your sign-in if it repeats."
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        } catch StoriesError.serverMessage(let message) {
            errorText = "\(publishFailureContext): \(message)"
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        } catch let StoriesError.serverUnavailable(statusCode) {
            let suffix = statusCode.map { " HTTP \($0)." } ?? ""
            errorText = "\(publishFailureContext): Flashes are temporarily unavailable.\(suffix)"
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        } catch {
            errorText = "\(publishFailureContext): \(error.localizedDescription)"
            reopenPostDrawerAfterPublishFailure()
            publishPhase = .idle
            publishProgress = 0
        }
    }

    private var publishFailureContext: String {
        switch publishPhase {
        case .idle:
            return "Flash publish"
        case .rendering:
            return "Rendering flash"
        case .preparingUpload:
            return "Preparing upload"
        case .uploading:
            return "Uploading media"
        case .publishing:
            return "Creating flash"
        case .processing:
            return "Processing flash video"
        case .complete:
            return "Flash publish"
        }
    }

    private func firstStoryLink(in project: Project) -> LinkOverlay? {
        project.tracks.overlays.compactMap { overlay in
            if case .link(let link) = overlay, validCTAURL(link.url) {
                return link
            }
            if case .interactive(let interactive) = overlay,
               interactive.kind == .link,
               let link = linkOverlay(from: interactive, canvas: project.canvas),
               validCTAURL(link.url) {
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

private struct StoryFinalSharePreview: View {
    let project: Project
    let fallbackImage: UIImage?

    @State private var renderedImage: UIImage?
    @State private var isRendering = false

    private let compositor = StoryCompositor()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        GeometryReader { proxy in
            let overlays = storyOverlays(in: project) ?? []
            let stickerScale = StoryOverlayLayout.stickerPresentationScale(for: project.canvas, in: proxy.size)

            ZStack {
                Color.black

                if let image = renderedImage ?? fallbackImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }

                ForEach(Array(overlays.enumerated()), id: \.offset) { index, overlay in
                    let base = StoryOverlayLayout.clampedBase(
                        overlay.base,
                        stickerSize: StoryOverlayLayout.estimatedStickerSize(for: overlay),
                        canvas: project.canvas,
                        viewportSize: proxy.size
                    )
                    StoryOverlayStickerView(
                        overlay: overlay,
                        overlayIndex: index,
                        isInteractive: false
                    )
                    .fixedSize(horizontal: true, vertical: true)
                    .scaleEffect((base.scale ?? 1) * stickerScale)
                    .rotationEffect(.degrees(base.rotation ?? 0))
                    .position(StoryOverlayLayout.position(for: base, canvas: project.canvas, in: proxy.size))
                }

                if isRendering {
                    ProgressView()
                        .tint(.white)
                        .padding(8)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: project.updatedAt) {
            await renderPreview()
        }
        .accessibilityLabel("Final flash viewer preview")
    }

    private func renderPreview() async {
        isRendering = true
        defer { isRendering = false }

        var mediaProject = project
        mediaProject.tracks.overlays.removeAll { overlay in
            if case .interactive = overlay { return true }
            return false
        }
        do {
            let store = await ProjectStore.shared.assetStore(for: project.id)
            let requestedTime = min(
                max(project.coverTimeSeconds, 0),
                max(project.totalDurationSeconds - 0.01, 0)
            )
            let buffer = try await compositor.render(
                project: mediaProject,
                assetStore: store,
                at: CMTime(seconds: requestedTime, preferredTimescale: projectTimeScale),
                quality: .full
            )
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
            renderedImage = UIImage(cgImage: cgImage)
        } catch {
            renderedImage = nil
        }
    }
}

private func storyCaptionPayload(caption: String, project: Project) -> String? {
    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    let captionHandles = Set(storyMentionHandles(in: trimmedCaption))
    let overlayHandles = storyMentionHandles(in: project)
    let missingOverlayMentions = overlayHandles
        .filter { !captionHandles.contains($0) }
        .map { "@\($0)" }

    let pieces = ([trimmedCaption].filter { !$0.isEmpty } + missingOverlayMentions)
    let merged = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return merged.isEmpty ? nil : merged
}

private func storyMentionHandles(in project: Project) -> [String] {
    var seen = Set<String>()
    return project.tracks.overlays.compactMap { overlay -> String? in
        guard case .interactive(let interactive) = overlay,
              interactive.kind == .mention,
              let handle = storyMentionHandles(in: interactive.subtitle ?? interactive.title).first else {
            return nil
        }
        return seen.insert(handle).inserted ? handle : nil
    }
}

private func storyOverlays(in project: Project) -> [StoryOverlay]? {
    let overlays = project.tracks.overlays.compactMap { overlay -> StoryOverlay? in
        guard case .interactive(let interactive) = overlay else { return nil }
        let base = StoryOverlayLayout.safeNormalizedBase(for: interactive, canvas: project.canvas)
        switch interactive.kind {
        case .link:
            let metadata = optionDictionary(interactive.options)
            let url = metadata["url"] ?? interactive.subtitle ?? ""
            guard validStoryOverlayURL(url) else { return nil }
            return .link(
                base: base,
                data: LinkOverlayData(url: url, label: interactive.title)
            )
        case .mention:
            let metadata = optionDictionary(interactive.options)
            guard let handle = metadata["handle"] ?? storyMentionHandles(in: interactive.subtitle ?? interactive.title).first else { return nil }
            return .mention(
                base: base,
                data: MentionOverlayData(
                    entityType: metadata["type"] ?? "user",
                    entityId: metadata["entityId"] ?? handle,
                    handle: handle,
                    displayName: interactive.title,
                    avatarUrl: nil
                )
            )
        case .location:
            let metadata = optionDictionary(interactive.options)
            return .location(
                base: base,
                data: LocationOverlayData(
                    name: interactive.title,
                    lat: Double(metadata["lat"] ?? ""),
                    lng: Double(metadata["lng"] ?? "")
                )
            )
        case .poll:
            let options = visibleInteractiveOptions(interactive.options)
            guard options.count >= 2 else { return nil }
            return .poll(base: base, data: PollOverlayData(
                question: interactive.title,
                options: options,
                votes: nil,
                totalVotes: nil,
                userVote: nil
            ))
        case .quiz:
            let metadata = optionDictionary(interactive.options)
            let options = visibleInteractiveOptions(interactive.options)
            guard options.count >= 2 else { return nil }
            let correctIndex = min(max(Int(metadata["correctIndex"] ?? "") ?? 0, 0), options.count - 1)
            return .quiz(base: base, data: QuizOverlayData(
                question: interactive.title,
                options: options,
                correctIndex: correctIndex,
                userAnswer: nil,
                isCorrect: nil
            ))
        case .question:
            return .question(base: base, data: QuestionOverlayData(
                prompt: interactive.title,
                replyCount: nil,
                userReplied: nil
            ))
        case .countdown:
            return .countdown(base: base, data: CountdownOverlayData(label: interactive.title, endsAt: interactive.targetDate ?? Date()))
        case .addYours, .avatar:
            return nil
        }
    }
    return overlays.isEmpty ? nil : overlays
}

private func visibleInteractiveOptions(_ options: [String]) -> [String] {
    options.filter { option in
        !option.contains("=")
    }
}

private func optionDictionary(_ options: [String]) -> [String: String] {
    options.reduce(into: [:]) { result, option in
        guard let separator = option.firstIndex(of: "=") else { return }
        let key = String(option[..<separator])
        let value = String(option[option.index(after: separator)...])
        result[key] = value
    }
}

private func linkOverlay(from interactive: StoryInteractiveOverlay, canvas: CanvasSpec) -> LinkOverlay? {
    let metadata = optionDictionary(interactive.options)
    let url = metadata["url"] ?? interactive.subtitle ?? ""
    guard validStoryOverlayURL(url) else { return nil }
    return LinkOverlay(
        label: interactive.title,
        url: url,
        transform: interactive.transform,
        timeRange: interactive.timeRange
    )
}

private func validStoryOverlayURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "westreem"
}

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func storyMentionHandles(in text: String?) -> [String] {
    guard let text, let regex = try? NSRegularExpression(pattern: #"@([a-zA-Z][a-zA-Z0-9_]{1,29})"#) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var seen = Set<String>()
    return regex.matches(in: text, range: range).compactMap { match in
        guard let handleRange = Range(match.range(at: 1), in: text) else { return nil }
        let handle = String(text[handleRange]).lowercased()
        return seen.insert(handle).inserted ? handle : nil
    }
}

private struct StoryBackgroundPublishRequest: @unchecked Sendable {
    let project: Project
    let selectedPublisher: UploadContext
    let uploadContext: ActiveContext?
    let caption: String
    let ctaLabel: String
    let ctaUrl: String
}

private final class StoryBackgroundPublisher: @unchecked Sendable {
    static let shared = StoryBackgroundPublisher()

    private init() {}

    func enqueue(_ request: StoryBackgroundPublishRequest) {
        Task.detached(priority: .userInitiated) {
            await Self.publish(request)
        }
    }

    private static func publish(_ request: StoryBackgroundPublishRequest) async {
        let progressID = await GlobalUploadProgressManager.shared.begin(
            title: "Posting flash",
            detail: "Rendering flash...",
            progress: 0.05
        )

        do {
            if let uploadContext = request.uploadContext {
                SessionStorage.activeContext = uploadContext
            }
            let export = try await StoryExportService().export(project: request.project) { progress in
                Task { @MainActor in
                    GlobalUploadProgressManager.shared.update(
                        id: progressID,
                        detail: "Rendering flash... \(Int(progress * 100))%",
                        progress: 0.05 + (progress * 0.30)
                    )
                }
            }
            if export.isCacheHit {
                await GlobalUploadProgressManager.shared.update(
                    id: progressID,
                    detail: "Using cached render...",
                    progress: 0.35
                )
            }
            await GlobalUploadProgressManager.shared.update(
                id: progressID,
                detail: "Preparing upload...",
                progress: 0.38
            )

            await GlobalUploadProgressManager.shared.update(
                id: progressID,
                detail: "Uploading media...",
                progress: 0.42
            )
            let uploadedMedia = try await StoryUploadPipeline.upload(export: export) { progress in
                Task { @MainActor in
                    GlobalUploadProgressManager.shared.update(
                        id: progressID,
                        detail: "Uploading media... \(Int(progress * 100))%",
                        progress: 0.42 + (progress * 0.45)
                    )
                }
            }

            await GlobalUploadProgressManager.shared.update(
                id: progressID,
                detail: "Creating flash...",
                progress: 0.92
            )
            let placedLink = firstStoryLink(in: request.project)
            let createdStory = try await StoriesAPIClient.shared.createStory(
                CreateStoryRequest(
                    publisherType: request.selectedPublisher.type,
                    publisherId: request.selectedPublisher.id,
                    mediaUrl: uploadedMedia.mediaUrl,
                    thumbnailUrl: uploadedMedia.thumbnailUrl,
                    mediaType: uploadedMedia.mediaType,
                    duration: uploadedMedia.duration,
                    caption: storyCaptionPayload(caption: request.caption, project: request.project),
                    captionHtml: nil,
                    overlays: storyOverlays(in: request.project),
                    ctaLabel: nilIfEmpty(placedLink?.label ?? request.ctaLabel),
                    ctaUrl: nilIfEmpty(placedLink?.url ?? request.ctaUrl),
                    expiresInHours: 24
                )
            )

            if uploadedMedia.mediaType.lowercased().contains("video") {
                await GlobalUploadProgressManager.shared.update(
                    id: progressID,
                    detail: "Processing video...",
                    progress: 0.96
                )
                try await StoryMediaReadiness.waitUntilReady(mediaUrl: uploadedMedia.mediaUrl, mediaType: uploadedMedia.mediaType) { progress in
                    Task { @MainActor in
                        GlobalUploadProgressManager.shared.update(
                            id: progressID,
                            detail: "Processing video... \(Int(progress * 100))%",
                            progress: 0.96 + (progress * 0.04)
                        )
                    }
                }
            }

            await MainActor.run {
                NotificationCenter.default.post(name: .storiesDidChange, object: nil)
            }
            await GlobalUploadProgressManager.shared.complete(
                id: progressID,
                title: "Flash ready",
                detail: "Your flash is live."
            )
            await notify(
                title: "Flash ready",
                body: "Your flash is live.",
                userInfo: [
                    "kind": "storyPublish",
                    "storyId": createdStory.id,
                    "groupId": "\(request.selectedPublisher.type):\(request.selectedPublisher.id)"
                ]
            )
        } catch {
            await GlobalUploadProgressManager.shared.fail(
                id: progressID,
                title: "Flash failed",
                detail: error.localizedDescription
            )
            await notify(
                title: "Flash failed to post",
                body: error.localizedDescription,
                userInfo: ["kind": "storyPublishFailed"]
            )
        }
    }

    private static func firstStoryLink(in project: Project) -> LinkOverlay? {
        project.tracks.overlays.compactMap { overlay in
            if case .link(let link) = overlay, validCTAURL(link.url) {
                return link
            }
            if case .interactive(let interactive) = overlay,
               interactive.kind == .link,
               let link = linkOverlay(from: interactive, canvas: project.canvas),
               validCTAURL(link.url) {
                return link
            }
            return nil
        }.first
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validCTAURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "westreem"
    }

    private static func notify(title: String, body: String, userInfo: [String: String] = [:]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        let updatedSettings = await center.notificationSettings()
        guard updatedSettings.authorizationStatus == .authorized
            || updatedSettings.authorizationStatus == .provisional
            || updatedSettings.authorizationStatus == .ephemeral else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: "story-publish-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

private struct StoryUploadedMedia {
    let mediaUrl: String
    let thumbnailUrl: String?
    let mediaType: String
    let duration: Int
}

private enum StoryUploadPipeline {
    private static let thumbnailMimeType = "image/jpeg"

    static func upload(
        export: StoryExportResult,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StoryUploadedMedia {
        let mediaType = export.mediaType.lowercased().contains("video") ? "video" : "image"
        let duration = try await validatedDuration(for: export, mediaType: mediaType)
        let uploadMimeType = export.mimeType

        let upload = try await StoriesAPIClient.shared.getUploadUrl(mimeType: uploadMimeType)
        guard let uploadURL = await StoriesAPIClient.shared.resolvedAllowedUploadURL(from: upload.uploadUrl) else {
            throw StoriesError.badURL
        }
        try await StoriesAPIClient.shared.uploadMedia(
            to: uploadURL,
            fileURL: export.url,
            mimeType: uploadMimeType,
            onProgress: progress
        )
        let mediaUrl = try await resolvedMediaUrl(after: upload)

        var thumbnailUrl: String?
        if mediaType == "video", let posterData = await posterJPEGData(for: export.url) {
            thumbnailUrl = try? await uploadThumbnail(data: posterData)
        }

        return StoryUploadedMedia(
            mediaUrl: mediaUrl,
            thumbnailUrl: thumbnailUrl,
            mediaType: mediaType,
            duration: duration
        )
    }

    private static func validatedDuration(for export: StoryExportResult, mediaType: String) async throws -> Int {
        guard mediaType == "video" else { return Int(storyMaxDurationSeconds) }
        let asset = AVURLAsset(url: export.url)
        let seconds = (try? await asset.load(.duration).seconds) ?? Double(export.duration)
        guard seconds.isFinite, seconds > 0 else {
            throw StoryCreatorError.message("Could not read the rendered video duration.")
        }
        guard seconds <= storyMaxDurationSeconds + 0.05 else {
            throw StoriesError.videoTooLong
        }
        return min(Int(storyMaxDurationSeconds), max(1, Int(ceil(seconds))))
    }

    private static func resolvedMediaUrl(after upload: UploadUrlResponse) async throws -> String {
        if upload.needsTranscode == true {
            guard let objectKey = upload.objectKey?.trimmingCharacters(in: .whitespacesAndNewlines), !objectKey.isEmpty else {
                throw StoriesError.missingMediaUrl
            }
            return try await StoriesAPIClient.shared.transcodeStoryMedia(objectKey: objectKey)
        }
        guard let deliveryUrl = upload.resolvedDeliveryUrl else {
            throw StoriesError.missingMediaUrl
        }
        return deliveryUrl
    }

    private static func uploadThumbnail(data: Data) async throws -> String {
        let upload = try await StoriesAPIClient.shared.getUploadUrl(mimeType: thumbnailMimeType)
        guard let uploadURL = await StoriesAPIClient.shared.resolvedAllowedUploadURL(from: upload.uploadUrl) else {
            throw StoriesError.badURL
        }
        try await StoriesAPIClient.shared.uploadMedia(
            to: uploadURL,
            data: data,
            mimeType: thumbnailMimeType
        ) { _ in }
        return try await resolvedMediaUrl(after: upload)
    }

    private static func posterJPEGData(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 540, height: 960)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
            let requestedTime = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: requestedTime, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
        }.value
    }
}

private enum StoryMediaReadiness {
    static func waitUntilReady(
        mediaUrl: String,
        mediaType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard mediaType.lowercased().contains("video") else {
            await MainActor.run { progress(1) }
            return
        }
        guard let url = C.mediaURL(mediaUrl) else {
            throw StoryCreatorError.message("Flash video URL is invalid.")
        }

        let deadline = Date().addingTimeInterval(30 * 60)
        let start = Date()
        var lastError: Error?

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                if try await isPlayableVideo(url: url) {
                    await MainActor.run { progress(1) }
                    return
                }
            } catch {
                lastError = error
            }

            let elapsed = Date().timeIntervalSince(start)
            await MainActor.run { progress(min(0.98, elapsed / (30 * 60))) }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }

        if let lastError {
            throw StoryCreatorError.message("Flash video is still processing: \(lastError.localizedDescription)")
        }
        throw StoryCreatorError.message("Flash video is still processing. Try again shortly.")
    }

    private static func isPlayableVideo(url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        async let playable = asset.load(.isPlayable)
        async let duration = asset.load(.duration)
        async let tracks = asset.loadTracks(withMediaType: .video)

        let isPlayable = try await playable
        let loadedDuration = try await duration
        let videoTracks = try await tracks
        return isPlayable
            && !videoTracks.isEmpty
            && loadedDuration.seconds.isFinite
            && loadedDuration.seconds > 0
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
    static let storyPublishNotificationTapped = Notification.Name("storyPublishNotificationTapped")
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
