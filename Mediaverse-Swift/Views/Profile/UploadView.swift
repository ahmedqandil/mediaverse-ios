import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PickedUploadVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            return PickedUploadVideo(url: destination)
        }
    }
}

private struct UploadThumbnailFrame: Identifiable {
    let id = UUID()
    let time: Double
    let image: UIImage
}

private extension UploadContext {
    func matches(_ other: UploadContext) -> Bool {
        id == other.id && type == other.type
    }
}

struct UploadView: View {
    enum PresentationStyle {
        case screen
        case createSheet
    }

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @EnvironmentObject private var globalUploads: GlobalUploadProgressManager
    @Environment(\.dismiss) private var dismiss

    private let presentationStyle: PresentationStyle
    private let onOptionSelected: () -> Void

    @State private var contexts: UploadContextsResponse?
    @State private var selectedDestination: UploadContext?
    @State private var appliedActiveContextKey: String?
    @State private var contentType = "video"
    @State private var title = ""
    @State private var description = ""
    @State private var visibility = "public"
    @State private var selectedPlaylistId: String?
    @State private var playlists = [UploadPlaylistOption]()
    @State private var linkVideos = [UploadLinkItem]()
    @State private var linkEpisodes = [UploadLinkItem]()
    @State private var linkedClipId: String?
    @State private var linkedEpisodeId: String?

    @State private var fileURL: URL?
    @State private var fileName = ""
    @State private var fileSize: Int64 = 0
    @State private var orientation = "horizontal"
    @State private var thumbnail: Image?
    @State private var thumbnailImageData: Data?
    @State private var thumbnailFrames = [UploadThumbnailFrame]()
    @State private var selectedThumbnailFrameId: UUID?
    @State private var selectedThumbnailTime = 0.5
    @State private var videoDuration = 0.0
    @State private var thumbnailScrubTask: Task<Void, Never>?
    @State private var thumbnailInspectionTask: Task<Void, Never>?
    @State private var isExtractingFrames = false
    @State private var isImportingVideo = false

    @State private var isLoading = true
    @State private var isPickingFile = false
    @State private var isPickingThumbnail = false
    @State private var isRecordingVideo = false
    @State private var isCreatingStory = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedThumbnailPhotoItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var uploadProgress = 0.0
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var createdVideoId: String?
    @State private var uploadedVideoIsReady = false
    @State private var showDestinationLookup = false
    @State private var showPlaylistLookup = false
    @State private var showLinkLookup = false
    @State private var showThumbnailCropper = false
    @State private var pendingThumbnailImage: UIImage?
    @State private var pendingThumbnailData: Data?
    @State private var destinationQuery = ""
    @State private var playlistQuery = ""
    @State private var linkQuery = ""
    @State private var showDiscardUploadConfirmation = false

    private let visibilityOptions = ["public", "unlisted", "private"]
    private var allDestinations: [UploadContext] { (contexts?.channels ?? []) + (contexts?.shows ?? []) }
    private var selectedPlaylist: UploadPlaylistOption? { playlists.first { $0.id == selectedPlaylistId } }
    private var selectedDestinationSubtitle: String {
        guard let selectedDestination else { return "Choose where this content will be published" }
        return selectedDestination.networkName ?? (selectedDestination.type == "show" ? "Show" : "Channel")
    }
    private var canSubmit: Bool {
        auth.isAuthenticated && fileURL != nil && thumbnail != nil && selectedDestination != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isUploading
    }
    private var bottomMenuClearance: CGFloat {
        presentationStyle == .screen ? 108 : 0
    }

    init(presentationStyle: PresentationStyle = .screen, onOptionSelected: @escaping () -> Void = {}) {
        self.presentationStyle = presentationStyle
        self.onOptionSelected = onOptionSelected
    }

    var body: some View {
        ZStack {
            if presentationStyle == .screen {
                C.bg.ignoresSafeArea()
            }

            if !auth.isAuthenticated {
                authRequiredState
            } else {
                authenticatedContent
            }
        }
        .navigationTitle(presentationStyle == .screen ? "Upload" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(presentationStyle == .createSheet ? .hidden : .visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if auth.isAuthenticated, fileURL != nil {
                stickySubmitBar
                    .padding(.bottom, bottomMenuClearance)
                    .background(C.bg.opacity(0.97))
            }
        }
        .photosPicker(
            isPresented: $isPickingFile,
            selection: $selectedPhotoItem,
            matching: .videos,
            preferredItemEncoding: .current
        )
        .photosPicker(
            isPresented: $isPickingThumbnail,
            selection: $selectedThumbnailPhotoItem,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await handlePhotoSelection(item) }
        }
        .onChange(of: selectedThumbnailPhotoItem) { _, item in
            guard let item else { return }
            Task { await handleThumbnailImageSelection(item) }
        }
        .fullScreenCover(isPresented: $isRecordingVideo) {
            VideoCameraPicker { url in
                handleCapturedVideo(url)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isCreatingStory) {
            StoryCreatorCoordinator(preselectedPublisher: selectedDestination) {
                isCreatingStory = false
            }
        }
        .sheet(isPresented: $showDestinationLookup) {
            UploadDestinationLookupSheet(
                destinations: allDestinations,
                selectedId: selectedDestination?.id,
                query: $destinationQuery
            ) { destination in
                selectedDestination = destination
                showDestinationLookup = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPlaylistLookup) {
            UploadPlaylistLookupSheet(
                playlists: playlists,
                selectedId: selectedPlaylistId,
                query: $playlistQuery
            ) { playlistId in
                selectedPlaylistId = playlistId
                showPlaylistLookup = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLinkLookup) {
            UploadLinkLookupSheet(
                videos: linkVideos,
                episodes: selectedDestination?.type == "show" ? linkEpisodes : [],
                selectedClipId: linkedClipId,
                selectedEpisodeId: linkedEpisodeId,
                query: $linkQuery
            ) { selection in
                switch selection {
                case .none:
                    linkedClipId = nil
                    linkedEpisodeId = nil
                case .clip(let id):
                    linkedClipId = id
                    linkedEpisodeId = nil
                case .episode(let id):
                    linkedClipId = nil
                    linkedEpisodeId = id
                }
                showLinkLookup = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showThumbnailCropper) {
            if let pendingThumbnailImage {
                ThumbnailCropperSheet(
                    image: pendingThumbnailImage,
                    aspectRatio: C.mediaAspectRatio(forContentType: contentType),
                    onCancel: {
                        clearPendingThumbnailCrop()
                    },
                    onApply: { croppedImage in
                        selectThumbnail(
                            croppedImage,
                            time: selectedThumbnailTime,
                            frameId: nil,
                            customData: croppedImage.jpegData(compressionQuality: 0.86) ?? pendingThumbnailData
                        )
                        clearPendingThumbnailCrop()
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .task {
            await loadContexts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { _ in
            Task { await reloadForContextChange() }
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated else { return }
            Task { await loadContexts() }
        }
        .onChange(of: selectedDestination?.id) { _, _ in
            Task { await loadDependentOptions() }
        }
        .onChange(of: contentType) { _, _ in
            if contentType == "video" {
                linkedClipId = nil
                linkedEpisodeId = nil
            }
            Task { await loadDependentOptions() }
        }
        .confirmationDialog("Discard this upload?", isPresented: $showDiscardUploadConfirmation, titleVisibility: .visible) {
            Button("Discard upload", role: .destructive) {
                discardSelectedUploadAndLeave()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected video, thumbnail choices, and upload details will be cleared.")
        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        if fileURL == nil && presentationStyle == .createSheet {
            uploadActionDrawer
        } else if fileURL == nil {
            uploadLandingPage
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if presentationStyle == .screen {
                        header
                    }
                    mediaSection
                    thumbnailSection
                    contentTypeSection
                    destinationSection
                    playlistSection
                    detailsSection
                    if contentType == "short" { linkSection }
                    uploadSection
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Upload")
                .font(.title2.bold())
                .foregroundStyle(C.text)
            Text("Publish a video or short to your channel or show.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
        }
    }

    private var uploadLandingPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(C.watch.opacity(0.18))
                                .frame(width: 48, height: 48)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(C.watch)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Create")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(C.text)
                            Text("Open the camera for a story, record a new video, or upload from your library.")
                                .font(.system(size: 13))
                                .foregroundStyle(C.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !allDestinations.isEmpty || isLoading {
                        destinationPickerRow
                    } else if let errorText {
                        drawerMessage(text: errorText, icon: "exclamationmark.triangle")
                    } else {
                        drawerMessage(text: "No channel or show destinations found yet.", icon: "tray")
                    }
                }
                .padding(16)
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(C.borderSubtle, lineWidth: 1)
                }

                VStack(spacing: 10) {
                    if isImportingVideo {
                        drawerMessage(text: "Importing selected video...", icon: "arrow.down.circle")
                    }

                    if platformConfig.storiesFeedEnabled {
                        uploadSourceButton(
                            icon: "circle.dashed.inset.filled",
                        title: "Add story",
                        subtitle: "Open the story camera for photo or portrait video"
                    ) {
                        C.lightHaptic()
                        isCreatingStory = true
                        onOptionSelected()
                    }
                    }

                    uploadSourceButton(
                        icon: "video.badge.plus",
                        title: "Record video",
                        subtitle: "Open the camera and record a new upload"
                    ) {
                        C.lightHaptic()
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            errorText = "Camera is not available on this device."
                            return
                        }
                        isRecordingVideo = true
                        onOptionSelected()
                    }

                    uploadSourceButton(
                        icon: "photo.on.rectangle.angled",
                        title: "Upload video",
                        subtitle: "Select an existing video from your library"
                    ) {
                        C.lightHaptic()
                        isPickingFile = true
                        onOptionSelected()
                    }
                }
            }
            .padding(C.pagePad)
            .padding(.bottom, 112)
        }
    }

    private var mediaSection: some View {
        section("Video Source") {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(C.watch.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(C.watch)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Text(formatBytes(fileSize))
                        .font(.system(size: 12))
                        .foregroundStyle(C.textTertiary)
                }
                Spacer()

                Button {
                    showDiscardUploadConfirmation = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.90))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUploading)
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isExtractingFrames {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8).tint(C.textMuted)
                    Text("Extracting frames...")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textMuted)
                }
            } else if thumbnail != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(C.watch)
                    Text("\(thumbnailFrames.count) frames · \(orientation.capitalized)")
                        .font(.system(size: 12))
                        .foregroundStyle(C.watch)
                }
            }
        }
    }

    private func uploadSourceButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(C.elevated)
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(C.watch)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(C.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isUploading || isExtractingFrames || isImportingVideo)
    }

    private var thumbnailSection: some View {
        section("Thumbnail") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    thumbnailPreview
                    Spacer(minLength: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            isPickingThumbnail = true
                        } label: {
                            Label("Upload image", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .tint(C.watch)
                        .disabled(fileURL == nil || isUploading || (isExtractingFrames && thumbnail == nil))

                        if thumbnailImageData != nil {
                            Text("Custom image selected")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(C.watch)
                        } else if thumbnail != nil {
                            Text("Frame \(formatTime(selectedThumbnailTime))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(C.textMuted)
                        }
                    }
                }

                if !thumbnailFrames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(thumbnailFrames) { frame in
                                thumbnailFrameButton(frame)
                            }
                        }
                    }
                }

                if fileURL != nil, videoDuration > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Pick frame")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(C.text)
                            Spacer()
                            Text(formatTime(selectedThumbnailTime))
                                .font(.system(size: 11))
                                .foregroundStyle(C.textTertiary)
                        }
                        Slider(
                            value: $selectedThumbnailTime,
                            in: 0...max(videoDuration, 0.1)
                        )
                        .tint(C.watch)
                        .onChange(of: selectedThumbnailTime) { _, time in
                            scheduleThumbnailScrub(at: time)
                        }
                    }
                }
            }
        }
    }

    private var thumbnailPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .aspectRatio(C.mediaAspectRatio(forContentType: contentType), contentMode: .fit)
                .frame(maxWidth: contentType == "short" ? 130 : .infinity)

            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(C.mediaAspectRatio(forContentType: contentType), contentMode: .fit)
                    .frame(maxWidth: contentType == "short" ? 130 : .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isExtractingFrames {
                VStack(spacing: 8) {
                    ProgressView().tint(C.textMuted)
                    Text("Extracting...")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textMuted)
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white.opacity(0.15))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func thumbnailFrameButton(_ frame: UploadThumbnailFrame) -> some View {
        Button {
            selectThumbnail(frame.image, time: frame.time, frameId: frame.id, customData: nil)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: frame.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: contentType == "short" ? 52 : 76)
                    .aspectRatio(C.mediaAspectRatio(forContentType: contentType), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(formatTime(frame.time))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selectedThumbnailFrameId == frame.id ? C.watch : C.borderSubtle, lineWidth: selectedThumbnailFrameId == frame.id ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var contentTypeSection: some View {
        section("Content Type") {
            HStack(spacing: 10) {
                Image(systemName: contentType == "short" ? "iphone" : "play.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .frame(width: 36, height: 36)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(contentType == "short" ? "Short" : "Video")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(fileURL == nil ? "Selected automatically after you choose or record a video." : "\(orientation.capitalized) upload detected from the selected video.")
                        .font(.system(size: 11))
                        .foregroundStyle(C.textTertiary)
                }
                Spacer()
            }
        }
    }

    private var destinationSection: some View {
        section("Destination") {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8).tint(C.textMuted)
                    Text("Loading destinations...")
                        .font(.system(size: 13))
                        .foregroundStyle(C.textMuted)
                }
                .padding(.vertical, 8)
            } else if allDestinations.isEmpty {
                Text("You need a channel or show before publishing this upload.")
                    .font(.system(size: 13))
                    .foregroundStyle(C.textTertiary)
            } else {
                Button {
                    destinationQuery = ""
                    showDestinationLookup = true
                } label: {
                    lookupRow(
                        icon: selectedDestination?.type == "show" ? "play.tv" : "dot.radiowaves.left.and.right",
                        title: selectedDestination?.name ?? "Search channels and shows...",
                        subtitle: selectedDestinationSubtitle,
                        badge: selectedDestination?.type == "show" ? "Show" : selectedDestination == nil ? nil : "Channel",
                        badgeColor: selectedDestination?.type == "show" ? C.play : C.watch
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var playlistSection: some View {
        section("Playlist") {
            if playlists.isEmpty {
                Text("No playlists for this \(selectedDestination?.type ?? "destination") yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(C.textTertiary)
            } else {
                Button {
                    playlistQuery = ""
                    showPlaylistLookup = true
                } label: {
                    lookupRow(
                        icon: "list.bullet.rectangle",
                        title: selectedPlaylist?.title ?? "None",
                        subtitle: selectedPlaylist.map { "\($0.count.items) items" } ?? "Do not add to a playlist",
                        badge: nil,
                        badgeColor: C.watch
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lookupRow(icon: String, title: String, subtitle: String, badge: String?, badgeColor: Color, destination: UploadContext? = nil) -> some View {
        HStack(spacing: 10) {
            if let destination {
                selectedDestinationAvatar(destination)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.textTertiary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(title == "None" || title.hasPrefix("Search") ? C.textTertiary : C.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(badgeColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(C.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var detailsSection: some View {
        section("Details") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Give your video a title", text: $title)
                    .textInputAutocapitalization(.sentences)
                    .uploadTextFieldStyle()

                TextField("Tell viewers about this...", text: $description, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .uploadTextFieldStyle()

                Picker("Visibility", selection: $visibility) {
                    ForEach(visibilityOptions, id: \.self) { option in
                        Text(option.capitalized).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var linkSection: some View {
        section("Link To") {
            VStack(alignment: .leading, spacing: 12) {
                if linkVideos.isEmpty && linkEpisodes.isEmpty {
                    Text("No videos or episodes are available to link yet.")
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                }

                if !linkVideos.isEmpty || !linkEpisodes.isEmpty {
                    Button {
                        linkQuery = ""
                        showLinkLookup = true
                    } label: {
                        lookupRow(
                            icon: "link",
                            title: selectedLinkTitle,
                            subtitle: selectedLinkSubtitle,
                            badge: nil,
                            badgeColor: C.watch
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedLinkTitle: String {
        if let linkedClipId, let item = linkVideos.first(where: { $0.id == linkedClipId }) {
            return item.displayTitle
        }
        if let linkedEpisodeId, let item = linkEpisodes.first(where: { $0.id == linkedEpisodeId }) {
            return item.displayTitle
        }
        return "Search videos and episodes..."
    }

    private var selectedLinkSubtitle: String {
        if linkedClipId != nil { return "Linked video or clip" }
        if linkedEpisodeId != nil { return "Linked episode" }
        return "Optional source for this short"
    }

    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isUploading || uploadProgress > 0 {
                ProgressView(value: uploadProgress)
                    .tint(C.watch)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func uploadedMediaRoute(id: String) -> AppRoute {
        AppRoute.media(
            id: id,
            type: contentType,
            showId: selectedDestination?.type == "show" ? selectedDestination?.id : nil,
            channelId: selectedDestination?.type == "channel" ? selectedDestination?.id : nil
        )
    }

    private func openUploadedMedia(id: String) {
        let route = uploadedMediaRoute(id: id)
        removeSelectedVideo()
        dismiss()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pushRouteRequested, object: route)
        }
    }

    private var uploadEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text("Choose what to create")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(C.text)
            Text("Use the drawer below to start a story, record a video, or choose an existing video.")
                .font(.system(size: 13))
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
        .padding(.horizontal, 20)
    }

    private var uploadActionDrawer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Create")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(C.text)
                Spacer()
                destinationStatus
            }

            if !allDestinations.isEmpty || isLoading {
                destinationPickerRow
            } else if let errorText {
                drawerMessage(text: errorText, icon: "exclamationmark.triangle")
            } else {
                drawerMessage(text: "No channel or show destinations found yet.", icon: "tray")
            }

            VStack(spacing: 9) {
                if isImportingVideo {
                    drawerMessage(text: "Importing selected video...", icon: "arrow.down.circle")
                }

                if platformConfig.storiesFeedEnabled {
                    uploadSourceButton(
                        icon: "circle.dashed.inset.filled",
                        title: "Story",
                        subtitle: "Capture a 24-hour photo or portrait video"
                    ) {
                        C.lightHaptic()
                        isCreatingStory = true
                    }
                }

                uploadSourceButton(
                    icon: "video.badge.plus",
                    title: "Record video",
                    subtitle: "Open the camera and record a new upload"
                ) {
                    C.lightHaptic()
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        errorText = "Camera is not available on this device."
                        return
                    }
                    isRecordingVideo = true
                }

                uploadSourceButton(
                    icon: "photo.on.rectangle.angled",
                    title: "Upload video",
                    subtitle: "Select an existing video from your library"
                ) {
                    C.lightHaptic()
                    isPickingFile = true
                }
            }
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, presentationStyle == .screen ? 12 : 18)
        .padding(.bottom, presentationStyle == .screen ? 10 : 18)
        .background(C.bg.opacity(presentationStyle == .screen ? 0.98 : 1))
        .overlay(alignment: .top) {
            if presentationStyle == .screen {
                Rectangle().fill(C.borderSubtle).frame(height: 1)
            }
        }
    }

    private var destinationStatus: some View {
        Group {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(C.textMuted)
                    Text("Loading")
                }
            } else {
                Text("\(allDestinations.count) destination\(allDestinations.count == 1 ? "" : "s")")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(C.textTertiary)
    }

    private var destinationPickerRow: some View {
        Button {
            guard !isLoading else { return }
            destinationQuery = ""
            showDestinationLookup = true
        } label: {
            lookupRow(
                icon: selectedDestination?.type == "show" ? "play.tv" : "dot.radiowaves.left.and.right",
                title: selectedDestination?.name ?? (isLoading ? "Loading destinations..." : "Search channels and shows..."),
                subtitle: selectedDestinationSubtitle,
                badge: selectedDestination?.type == "show" ? "Show" : selectedDestination == nil ? nil : "Channel",
                badgeColor: selectedDestination?.type == "show" ? C.play : C.watch,
                destination: selectedDestination
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.72 : 1)
    }

    private func selectedDestinationAvatar(_ destination: UploadContext) -> some View {
        CachedRemoteImage(
            url: C.mediaURL(destination.avatarUrl),
            targetSize: CGSize(width: 28, height: 28)
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                (destination.type == "show" ? C.play : C.watch).opacity(0.15)
                Text(String(destination.name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: destination.type == "show" ? 5 : 14))
    }

    private func drawerMessage(text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(2)
            Spacer()
            if !isLoading {
                Button("Retry") {
                    Task { await loadContexts() }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(C.watch)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(C.textTertiary)
        .padding(10)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var stickySubmitBar: some View {
        VStack(spacing: 8) {
            submitButton
            if isUploading {
                ProgressView(value: uploadProgress)
                    .tint(C.watch)
            }
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(C.bg.opacity(0.97))
        .overlay(Rectangle().fill(C.borderSubtle).frame(height: 1), alignment: .top)
    }

    private var submitButton: some View {
        Button {
            if uploadedVideoIsReady, let createdVideoId {
                openUploadedMedia(id: createdVideoId)
            } else {
                Task { await submitUpload() }
            }
        } label: {
            HStack(spacing: 8) {
                if isUploading || isExtractingFrames {
                    ProgressView().tint(.black)
                } else if uploadedVideoIsReady {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                } else if canSubmit {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(submitTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(C.watch)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isSubmitButtonProminent ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isSubmitButtonEnabled)
    }

    private var isSubmitButtonEnabled: Bool {
        uploadedVideoIsReady || canSubmit
    }

    private var isSubmitButtonProminent: Bool {
        isSubmitButtonEnabled || isUploading || isExtractingFrames
    }

    private var submitTitle: String {
        if uploadedVideoIsReady { return "Watch it online" }
        if isUploading { return statusText.isEmpty ? "Uploading..." : statusText }
        if fileURL == nil { return "Select a video to start" }
        if thumbnail == nil && isExtractingFrames { return "Preparing preview..." }
        if thumbnail == nil { return "Add a thumbnail to continue" }
        if selectedDestination == nil { return "Choose a destination" }
        return "Upload \(contentType == "short" ? "Short" : "Video")"
    }

    private var authRequiredState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.to.line.compact")
                .font(.system(size: 44))
                .foregroundStyle(C.textMuted)
            Text("Sign in to upload")
                .font(.title3.bold())
                .foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDestinationState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 42))
                .foregroundStyle(C.textMuted)
            Text("You need a channel to upload")
                .font(.title3.bold())
                .foregroundStyle(C.text)
            Text("Create a channel first, then return here to publish videos or shorts.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(C.textTertiary)
            content()
        }
        .padding(14)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func reloadForContextChange() async {
        UploadOptionsCache.clear()
        appliedActiveContextKey = nil
        selectedDestination = nil
        selectedPlaylistId = nil
        playlists = []
        linkVideos = []
        linkEpisodes = []
        linkedClipId = nil
        linkedEpisodeId = nil
        await loadContexts()
    }

    private func loadContexts() async {
        guard auth.isAuthenticated else {
            isLoading = false
            return
        }

        if let cached = UploadOptionsCache.contexts {
            applyContexts(cached)
            isLoading = false
            Task { await loadDependentOptions() }
        } else {
            isLoading = true
        }

        do {
            let response = try await UploadOptionsCache.refreshContexts()
            applyContexts(response)
            isLoading = false
            Task { await loadDependentOptions() }
        } catch {
            isLoading = false
            errorText = error.localizedDescription
        }
    }

    private func applyContexts(_ response: UploadContextsResponse) {
        contexts = response
        let activeKey = activeContextDestinationKey
        let destinations = response.channels + response.shows
        let preferredDestination = destinationForActiveContext(in: response)
        let didActiveContextChange = appliedActiveContextKey != activeKey

        if didActiveContextChange, let preferredDestination {
            selectedDestination = preferredDestination
            appliedActiveContextKey = activeKey
            return
        }

        if let selectedDestination,
           destinations.contains(where: { $0.matches(selectedDestination) }) {
            appliedActiveContextKey = activeKey
            return
        }

        selectedDestination = preferredDestination ?? response.channels.first ?? response.shows.first
        appliedActiveContextKey = activeKey
    }

    private var activeContextDestinationKey: String? {
        guard let activeContext = SessionStorage.activeContext else { return nil }
        return [
            activeContext.type,
            activeContext.id,
            activeContext.showId ?? "",
            activeContext.channelId ?? "",
            activeContext.networkId ?? ""
        ].joined(separator: ":")
    }

    private func destinationForActiveContext(in response: UploadContextsResponse) -> UploadContext? {
        guard let activeContext = SessionStorage.activeContext else { return nil }
        let type = activeContext.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let candidateShowIDs = [type == "show" ? activeContext.id : nil, activeContext.showId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for showID in candidateShowIDs {
            if let show = response.shows.first(where: { $0.id == showID || $0.showId == showID }) {
                return show
            }
        }

        let candidateChannelIDs = [type == "channel" ? activeContext.id : nil, activeContext.channelId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for channelID in candidateChannelIDs {
            if let channel = response.channels.first(where: { $0.id == channelID || $0.channelId == channelID }) {
                return channel
            }
            if let show = response.shows.first(where: { $0.channelId == channelID }) {
                return show
            }
        }

        return nil
    }

    private func uploadLimitChannelId(for destination: UploadContext) -> String? {
        if destination.type == "channel" {
            return destination.id
        }
        if let channelId = destination.channelId?.trimmingCharacters(in: .whitespacesAndNewlines), !channelId.isEmpty {
            return channelId
        }
        return nil
    }

    private func loadDependentOptions() async {
        guard let selectedDestination else { return }
        selectedPlaylistId = nil
        playlists = (try? await APIClient.shared.fetchUploadPlaylists(destination: selectedDestination, contentType: contentType)) ?? []

        guard contentType == "short" else {
            linkVideos = []
            linkEpisodes = []
            return
        }
        async let videosTask = APIClient.shared.fetchUploadLinkVideos(destination: selectedDestination)
        async let episodesTask = selectedDestination.type == "show"
            ? APIClient.shared.fetchUploadLinkEpisodes(showId: selectedDestination.id)
            : [UploadLinkItem]()
        linkVideos = (try? await videosTask) ?? []
        linkEpisodes = (try? await episodesTask) ?? []
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let pickedURL = try result.get().first else { return }
            let didAccess = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { pickedURL.stopAccessingSecurityScopedResource() }
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pickedURL.pathExtension.isEmpty ? "mov" : pickedURL.pathExtension)
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: pickedURL, to: tempURL)
            let values = try tempURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            fileURL = tempURL
            fileName = values.name ?? pickedURL.lastPathComponent
            fileSize = Int64(values.fileSize ?? 0)
            title = title.isEmpty ? pickedURL.deletingPathExtension().lastPathComponent : title
            thumbnail = nil
            thumbnailImageData = nil
            thumbnailFrames = []
            selectedThumbnailFrameId = nil
            videoDuration = 0
            selectedThumbnailTime = 0.5
            errorText = nil
            isExtractingFrames = true

            startVideoInspection(tempURL)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        await MainActor.run {
            errorText = nil
            isImportingVideo = true
            thumbnail = nil
            thumbnailImageData = nil
            thumbnailFrames = []
            selectedThumbnailFrameId = nil
            videoDuration = 0
            selectedThumbnailTime = 0.5
            isExtractingFrames = true
        }

        do {
            guard let picked = try await item.loadTransferable(type: PickedUploadVideo.self) else {
                throw UploadFailure.message("Could not read the selected video from Photos.")
            }

            try await prepareSelectedVideo(picked.url)
            await MainActor.run {
                isImportingVideo = false
                startVideoInspection(picked.url)
            }
        } catch {
            await MainActor.run {
                selectedPhotoItem = nil
                isImportingVideo = false
                isExtractingFrames = false
                errorText = error.localizedDescription
            }
        }
    }

    private func handleCapturedVideo(_ url: URL) {
        Task {
            await MainActor.run {
                errorText = nil
                thumbnail = nil
                thumbnailImageData = nil
                thumbnailFrames = []
                selectedThumbnailFrameId = nil
                videoDuration = 0
                selectedThumbnailTime = 0.5
                isExtractingFrames = true
            }

            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                try await prepareSelectedVideo(tempURL)
                await MainActor.run {
                    startVideoInspection(tempURL)
                }
            } catch {
                await MainActor.run {
                    isExtractingFrames = false
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func prepareSelectedVideo(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let displayName = values.name ?? url.lastPathComponent
        let titleName = url.deletingPathExtension().lastPathComponent
        let previousURL = fileURL
        await MainActor.run {
            if let previousURL, previousURL != url {
                deleteTemporaryUploadFile(previousURL)
            }
            fileURL = url
            fileName = displayName
            fileSize = Int64(values.fileSize ?? 0)
            title = title.isEmpty ? titleName : title
            createdVideoId = nil
            uploadedVideoIsReady = false
            uploadProgress = 0
            statusText = ""
            errorText = nil
            selectedPhotoItem = nil
        }
    }

    private func startVideoInspection(_ url: URL) {
        thumbnailInspectionTask?.cancel()
        thumbnailInspectionTask = Task {
            await inspectVideo(url)
        }
    }

    private func inspectVideo(_ url: URL) async {
        defer {
            Task { @MainActor in
                guard fileURL == url else { return }
                isExtractingFrames = false
                thumbnailInspectionTask = nil
            }
        }

        let asset = AVAsset(url: url)
        guard !Task.isCancelled,
              let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformedSize = size.applying(transform)
        let displayWidth = abs(transformedSize.width) > 0 ? abs(transformedSize.width) : abs(size.width)
        let displayHeight = abs(transformedSize.height) > 0 ? abs(transformedSize.height) : abs(size.height)
        let detectedOrientation = displayHeight > displayWidth ? "vertical" : "horizontal"
        let duration = max((try? await asset.load(.duration).seconds) ?? 0, 0)
        let firstFrameTime = min(0.5, max(duration, 0))

        await MainActor.run {
            guard fileURL == url else { return }
            orientation = detectedOrientation
            contentType = detectedOrientation == "vertical" ? "short" : "video"
            videoDuration = duration
        }

        if !Task.isCancelled,
           let image = try? frameImage(from: asset, at: firstFrameTime, exact: false) {
            let frame = UploadThumbnailFrame(time: firstFrameTime, image: image)
            await MainActor.run {
                guard fileURL == url else { return }
                thumbnailFrames = [frame]
                selectThumbnail(frame.image, time: frame.time, frameId: frame.id, customData: nil)
            }
        }

        await extractThumbnailFrames(from: asset, duration: duration, selectedURL: url)
    }

    private func extractThumbnailFrames(from asset: AVAsset, duration: Double, selectedURL: URL) async {
        let count = 8
        let safeDuration = max(duration, 1)
        let times = (0..<count).map { index in
            safeDuration * (Double(index) + 0.5) / Double(count)
        }

        for time in times {
            guard !Task.isCancelled else { return }
            guard let image = try? frameImage(from: asset, at: time, exact: false) else { continue }
            let frame = UploadThumbnailFrame(time: time, image: image)
            await MainActor.run {
                guard fileURL == selectedURL, !thumbnailFrames.contains(where: { abs($0.time - frame.time) < 0.05 }) else { return }
                thumbnailFrames.append(frame)
                thumbnailFrames.sort { $0.time < $1.time }
            }
        }
    }

    private func frameImage(from asset: AVAsset, at seconds: Double, exact: Bool = true) throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        } else {
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
        }
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    private func handleThumbnailImageSelection(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw UploadFailure.message("Could not read the selected thumbnail image.")
            }
            await MainActor.run {
                pendingThumbnailImage = image
                pendingThumbnailData = image.jpegData(compressionQuality: 0.86) ?? data
                showThumbnailCropper = true
                selectedThumbnailPhotoItem = nil
            }
        } catch {
            await MainActor.run {
                selectedThumbnailPhotoItem = nil
                errorText = error.localizedDescription
            }
        }
    }

    private func selectThumbnail(_ image: UIImage, time: Double, frameId: UUID?, customData: Data?) {
        thumbnail = Image(uiImage: image)
        thumbnailImageData = customData
        selectedThumbnailFrameId = frameId
        selectedThumbnailTime = min(max(time, 0), max(videoDuration, 0.1))
    }

    private func clearPendingThumbnailCrop() {
        showThumbnailCropper = false
        pendingThumbnailImage = nil
        pendingThumbnailData = nil
        selectedThumbnailPhotoItem = nil
    }

    private func scheduleThumbnailScrub(at time: Double) {
        guard let fileURL, thumbnailImageData == nil else { return }
        thumbnailScrubTask?.cancel()
        thumbnailScrubTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await pickThumbnailFrame(at: time, fileURL: fileURL)
        }
    }

    private func pickThumbnailFrame(at time: Double, fileURL: URL) async {
        let asset = AVAsset(url: fileURL)
        guard let image = try? frameImage(from: asset, at: time) else { return }
        await MainActor.run {
            selectThumbnail(image, time: time, frameId: nil, customData: nil)
        }
    }

    private func removeSelectedVideo() {
        guard !isUploading else { return }
        let fileToDelete = fileURL
        thumbnailInspectionTask?.cancel()
        thumbnailInspectionTask = nil
        if let fileToDelete {
            deleteTemporaryUploadFile(fileToDelete)
        }
        fileURL = nil
        fileName = ""
        fileSize = 0
        orientation = "horizontal"
        thumbnail = nil
        thumbnailImageData = nil
        thumbnailFrames = []
        selectedThumbnailFrameId = nil
        videoDuration = 0
        selectedThumbnailTime = 0.5
        thumbnailScrubTask?.cancel()
        thumbnailScrubTask = nil
        isExtractingFrames = false
        isImportingVideo = false
        createdVideoId = nil
        uploadedVideoIsReady = false
        uploadProgress = 0
        statusText = ""
        errorText = nil
    }

    private func discardSelectedUploadAndLeave() {
        removeSelectedVideo()
        if presentationStyle == .createSheet {
            dismiss()
        }
    }

    private func deleteTemporaryUploadFile(_ url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func submitUpload() async {
        guard let fileURL, let selectedDestination else { return }
        isUploading = true
        errorText = nil
        createdVideoId = nil
        uploadedVideoIsReady = false
        uploadProgress = 0
        statusText = "Preparing upload..."
        let globalProgressID = globalUploads.begin(title: "Uploading video", detail: "Preparing upload...", progress: 0)
        defer { isUploading = false }

        do {
            let oneGb: Int64 = 1024 * 1024 * 1024
            if fileSize > oneGb {
                throw UploadFailure.message("Video files must be under 1 GB. Please compress your video before uploading.")
            }

            let channelId = uploadLimitChannelId(for: selectedDestination)
            let cf = try await APIClient.shared.createCfStreamUpload(fileSize: fileSize, channelId: channelId)
            if let limit = cf.uploadLimitBytes, fileSize > Int64(limit) {
                let mb = Int64(limit) / 1024 / 1024
                throw UploadFailure.message("Video exceeds the \(mb) MB upload limit for this channel.")
            }
            guard let uploadURL = URL(string: cf.uploadUrl) else {
                throw APIError.badURL(cf.uploadUrl)
            }

            statusText = "Uploading video..."
            globalUploads.update(id: globalProgressID, detail: "Uploading video...", progress: 0.02)
            try await APIClient.shared.uploadToTus(uploadUrl: uploadURL, fileURL: fileURL, fileSize: fileSize) { pct in
                await MainActor.run {
                    let progress = pct * 0.68
                    uploadProgress = progress
                    statusText = "Uploading video... \(Int(pct * 100))%"
                    globalUploads.update(id: globalProgressID, detail: statusText, progress: progress)
                }
            }

            uploadProgress = 0.72
            statusText = "Saving..."
            globalUploads.update(id: globalProgressID, detail: "Preparing media details...", progress: 0.72)
            let thumbnailUrl: String
            if let thumbnailImageData {
                statusText = "Uploading thumbnail..."
                globalUploads.update(id: globalProgressID, detail: "Uploading thumbnail...", progress: 0.76)
                thumbnailUrl = try await APIClient.shared.uploadThumbnailImage(thumbnailImageData)
            } else {
                thumbnailUrl = cloudflareThumbnailUrl(streamId: cf.streamId, time: selectedThumbnailTime)
            }

            uploadProgress = 0.85
            statusText = "Saving..."
            globalUploads.update(id: globalProgressID, detail: "Saving video...", progress: 0.85)
            let video = try await APIClient.shared.createUploadedVideo(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
                visibility: visibility,
                orientation: orientation,
                type: contentType,
                destination: selectedDestination,
                playlistId: selectedPlaylistId,
                linkedClipId: linkedClipId,
                linkedEpisodeId: linkedEpisodeId,
                cfStreamId: cf.streamId,
                thumbnailUrl: thumbnailUrl
            )
            createdVideoId = video.id
            uploadProgress = 0.85
            statusText = "Transcoding..."
            globalUploads.update(id: globalProgressID, detail: "Transcoding...", progress: 0.85)
            let isReady = await pollTranscode(videoId: video.id, globalProgressID: globalProgressID)
            uploadedVideoIsReady = isReady
            let videoTitle = video.title ?? title
            try? await APIClient.shared.createNotification(
                type: "upload_complete",
                title: isReady ? "Video ready" : "Upload complete",
                message: isReady
                    ? "\"\(videoTitle)\" finished transcoding and is ready to watch."
                    : "\"\(videoTitle)\" uploaded and is still processing.",
                linkUrl: contentType == "short" ? "/shorts/\(video.id)" : "/watch/\(video.id)"
            )
            statusText = isReady ? "Video ready" : "Upload complete - still processing"
            globalUploads.complete(
                id: globalProgressID,
                title: isReady ? "Video ready" : "Upload complete",
                detail: isReady ? "Your video is ready to watch." : "Your video is still processing."
            )
        } catch {
            uploadProgress = 0
            errorText = friendlyError(error)
            statusText = errorText ?? "Upload failed"
            globalUploads.fail(id: globalProgressID, title: "Upload failed", detail: statusText)
        }
    }

    private func pollTranscode(videoId: String, globalProgressID: UUID) async -> Bool {
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            do {
                let status = try await APIClient.shared.fetchUploadStreamStatus(videoId: videoId)
                let transcodeProgress = min(99, status.pct)
                let progress = min(0.99, 0.85 + (Double(transcodeProgress) / 100 * 0.14))
                uploadProgress = progress
                statusText = status.ready ? "Video ready" : "Transcoding... \(transcodeProgress)%"
                globalUploads.update(id: globalProgressID, detail: statusText, progress: progress)
                if status.ready {
                    uploadProgress = 1
                    globalUploads.update(id: globalProgressID, detail: "Video ready", progress: 1)
                    return true
                }
            } catch {
                // Network blips should not fail the completed upload.
            }
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func cloudflareThumbnailUrl(streamId: String, time: Double) -> String {
        let seconds = max(0, time)
        return "https://videodelivery.net/\(streamId)/thumbnails/thumbnail.jpg?time=\(String(format: "%.2f", seconds))s"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds.rounded()), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func friendlyError(_ error: Error) -> String {
        if let failure = error as? UploadFailure { return failure.localizedDescription }
        if error.localizedDescription == "The Internet connection appears to be offline." {
            return "Network error - check your connection and try again."
        }
        return error.localizedDescription
    }
}

private struct UploadDestinationLookupSheet: View {
    let destinations: [UploadContext]
    let selectedId: String?
    @Binding var query: String
    let onSelect: (UploadContext) -> Void

    private var filtered: [UploadContext] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return destinations }
        return destinations.filter {
            $0.name.lowercased().contains(trimmed) || ($0.networkName ?? "").lowercased().contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 12) {
                    searchField(placeholder: "Search channels and shows...")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            destinationGroup(title: "Channels", items: filtered.filter { $0.type == "channel" })
                            destinationGroup(title: "Shows", items: filtered.filter { $0.type == "show" })
                            if filtered.isEmpty {
                                Text("No matches for \"\(query)\"")
                                    .font(.system(size: 13))
                                    .foregroundStyle(C.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func destinationGroup(title: String, items: [UploadContext]) -> some View {
        Group {
            if !items.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(C.textTertiary)
                    .padding(.top, 4)
                ForEach(items) { item in
                    Button { onSelect(item) } label: {
                        HStack(spacing: 12) {
                            avatar(for: item)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(C.text)
                                    .lineLimit(1)
                                if let network = item.networkName {
                                    Text(network)
                                        .font(.system(size: 11))
                                        .foregroundStyle(C.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if item.id == selectedId {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(C.watch)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(C.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func avatar(for destination: UploadContext) -> some View {
        CachedRemoteImage(
            url: C.mediaURL(destination.avatarUrl),
            targetSize: CGSize(width: 28, height: 28)
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                destination.type == "show" ? C.play.opacity(0.15) : C.watch.opacity(0.15)
                Text(String(destination.name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: destination.type == "show" ? 5 : 14))
    }

    private func searchField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(C.textTertiary)
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(C.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum UploadLinkSelection {
    case none
    case clip(String)
    case episode(String)
}

private struct UploadLinkLookupSheet: View {
    let videos: [UploadLinkItem]
    let episodes: [UploadLinkItem]
    let selectedClipId: String?
    let selectedEpisodeId: String?
    @Binding var query: String
    let onSelect: (UploadLinkSelection) -> Void

    private var filteredVideos: [UploadLinkItem] {
        filter(videos)
    }

    private var filteredEpisodes: [UploadLinkItem] {
        filter(episodes)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 12) {
                    searchField
                    ScrollView {
                        VStack(spacing: 8) {
                            linkButton(
                                title: "None - do not link this short",
                                subtitle: nil,
                                icon: "xmark.circle",
                                selected: selectedClipId == nil && selectedEpisodeId == nil
                            ) {
                                onSelect(.none)
                            }

                            linkGroup(title: "Videos", items: filteredVideos, icon: "play.rectangle") { item in
                                onSelect(.clip(item.id))
                            }

                            linkGroup(title: "Episodes", items: filteredEpisodes, icon: "tv") { item in
                                onSelect(.episode(item.id))
                            }

                            if filteredVideos.isEmpty,
                               filteredEpisodes.isEmpty,
                               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No matches for \"\(query)\"")
                                    .font(.system(size: 13))
                                    .foregroundStyle(C.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Link To")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func filter(_ items: [UploadLinkItem]) -> [UploadLinkItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.displayTitle.lowercased().contains(trimmed) }
    }

    private func linkGroup(
        title: String,
        items: [UploadLinkItem],
        icon: String,
        action: @escaping (UploadLinkItem) -> Void
    ) -> some View {
        Group {
            if !items.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(C.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                ForEach(items) { item in
                    linkButton(
                        title: item.displayTitle,
                        subtitle: nil,
                        icon: icon,
                        selected: item.id == selectedClipId || item.id == selectedEpisodeId
                    ) {
                        action(item)
                    }
                }
            }
        }
    }

    private func linkButton(
        title: String,
        subtitle: String?,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? C.watch : C.text)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(C.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(C.watch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(C.textTertiary)
            TextField("Search videos and episodes", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(C.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct VideoCameraPicker: UIViewControllerRepresentable {
    let onVideo: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVideo: onVideo)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.cameraFlashMode = .off
        picker.showsCameraControls = false
        picker.delegate = context.coordinator
        picker.cameraOverlayView = context.coordinator.makeOverlay(for: picker)
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onVideo: (URL) -> Void
        private weak var picker: UIImagePickerController?
        private weak var overlay: UploadCameraOverlayView?
        private var isRecording = false
        private var recordingStartedAt: Date?
        private var timer: Timer?
        private var flashMode: UIImagePickerController.CameraFlashMode = .off
        private var zoomScale: CGFloat = 1

        init(onVideo: @escaping (URL) -> Void) {
            self.onVideo = onVideo
        }

        func makeOverlay(for picker: UIImagePickerController) -> UIView {
            self.picker = picker
            let overlay = UploadCameraOverlayView(frame: UIScreen.main.bounds)
            overlay.onClose = { [weak self] in
                self?.stopTimer()
                self?.picker?.dismiss(animated: true)
            }
            overlay.onRecord = { [weak self] in
                self?.toggleRecording()
            }
            overlay.onFlip = { [weak self] in
                self?.flipCamera()
            }
            overlay.onFlash = { [weak self] in
                self?.toggleFlash()
            }
            overlay.onZoomChanged = { [weak self] value in
                self?.setZoom(CGFloat(value))
            }
            overlay.onResetZoom = { [weak self] in
                self?.setZoom(1)
            }
            self.overlay = overlay
            updateCameraTools()
            return overlay
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            stopTimer()
            overlay?.setRecording(false)
            picker.dismiss(animated: true)
            if let url = info[.mediaURL] as? URL {
                onVideo(url)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            stopTimer()
            picker.dismiss(animated: true)
        }

        private func toggleRecording() {
            guard let picker else { return }
            if isRecording {
                picker.stopVideoCapture()
                isRecording = false
                overlay?.setRecording(false)
                stopTimer()
            } else if picker.startVideoCapture() {
                isRecording = true
                recordingStartedAt = Date()
                overlay?.setRecording(true)
                startTimer()
            }
        }

        private func flipCamera() {
            guard let picker, !isRecording else { return }
            let nextDevice: UIImagePickerController.CameraDevice = picker.cameraDevice == .rear ? .front : .rear
            guard UIImagePickerController.isCameraDeviceAvailable(nextDevice) else { return }
            picker.cameraDevice = nextDevice
            flashMode = .off
            picker.cameraFlashMode = .off
            setZoom(1)
            updateCameraTools()
        }

        private func toggleFlash() {
            guard let picker, UIImagePickerController.isFlashAvailable(for: picker.cameraDevice) else { return }
            switch flashMode {
            case .off:
                flashMode = .on
            case .on:
                flashMode = .auto
            case .auto:
                flashMode = .off
            @unknown default:
                flashMode = .off
            }
            picker.cameraFlashMode = flashMode
            overlay?.updateFlash(mode: flashMode, isAvailable: true)
        }

        private func setZoom(_ scale: CGFloat) {
            guard let picker else { return }
            zoomScale = min(max(scale, 1), 3)
            picker.cameraViewTransform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
            overlay?.updateZoom(Double(zoomScale))
        }

        private func updateCameraTools() {
            guard let picker else { return }
            let isFlashAvailable = UIImagePickerController.isFlashAvailable(for: picker.cameraDevice)
            overlay?.updateFlash(mode: isFlashAvailable ? flashMode : .off, isAvailable: isFlashAvailable)
            overlay?.updateZoom(Double(zoomScale))
        }

        private func startTimer() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateElapsedTime()
            }
            updateElapsedTime()
        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
            recordingStartedAt = nil
            overlay?.updateElapsedTime("00:00")
        }

        private func updateElapsedTime() {
            guard let recordingStartedAt else { return }
            let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            overlay?.updateElapsedTime(String(format: "%02d:%02d", minutes, seconds))
        }
    }
}

private final class UploadCameraOverlayView: UIView {
    var onClose: (() -> Void)?
    var onRecord: (() -> Void)?
    var onFlip: (() -> Void)?
    var onFlash: (() -> Void)?
    var onZoomChanged: ((Double) -> Void)?
    var onResetZoom: (() -> Void)?

    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let toolRail = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let titleLabel = UILabel()
    private let timerLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let recordButton = UIButton(type: .system)
    private let flipButton = UIButton(type: .system)
    private let flashButton = UIButton(type: .system)
    private let zoom1Button = UIButton(type: .system)
    private let zoom2Button = UIButton(type: .system)
    private let zoom3Button = UIButton(type: .system)
    private let zoomLabel = UILabel()
    private let recordingDot = UIView()
    private var currentZoom: Double = 1
    private var pinchStartZoom: Double = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        configureTopBar()
        configureToolRail()
        configureBottomBar()
        configureButtons()
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setRecording(_ recording: Bool) {
        recordingDot.isHidden = !recording
        flipButton.isEnabled = !recording
        flipButton.alpha = recording ? 0.35 : 1
        recordButton.layer.borderColor = recording ? UIColor.white.cgColor : UIColor(red: 0, green: 0.90, blue: 0.46, alpha: 1).cgColor
        recordButton.backgroundColor = recording ? UIColor(red: 0.96, green: 0.10, blue: 0.16, alpha: 1) : UIColor(red: 0, green: 0.90, blue: 0.46, alpha: 1)
        recordButton.setImage(UIImage(systemName: recording ? "stop.fill" : "record.circle"), for: .normal)
        titleLabel.text = recording ? "Recording upload" : "Record upload"
    }

    func updateElapsedTime(_ value: String) {
        timerLabel.text = value
    }

    func updateFlash(mode: UIImagePickerController.CameraFlashMode, isAvailable: Bool) {
        flashButton.isEnabled = isAvailable
        flashButton.alpha = isAvailable ? 1 : 0.35
        let imageName: String
        switch mode {
        case .on:
            imageName = "bolt.fill"
        case .auto:
            imageName = "bolt.badge.a.fill"
        case .off:
            imageName = "bolt.slash.fill"
        @unknown default:
            imageName = "bolt.slash.fill"
        }
        flashButton.setImage(UIImage(systemName: imageName), for: .normal)
    }

    func updateZoom(_ value: Double) {
        currentZoom = min(max(value, 1), 3)
        zoomLabel.text = String(format: "%.1fx", currentZoom)
        updateZoomButtonSelection()
    }

    private func configureTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.layer.cornerRadius = 18
        topBar.layer.cornerCurve = .continuous
        topBar.clipsToBounds = true
        addSubview(topBar)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Record upload"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)

        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.text = "00:00"
        timerLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        recordingDot.backgroundColor = UIColor(red: 0.96, green: 0.10, blue: 0.16, alpha: 1)
        recordingDot.layer.cornerRadius = 4
        recordingDot.isHidden = true

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .white
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        closeButton.layer.cornerRadius = 17
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        topBar.contentView.addSubview(closeButton)
        topBar.contentView.addSubview(titleLabel)
        topBar.contentView.addSubview(recordingDot)
        topBar.contentView.addSubview(timerLabel)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            topBar.heightAnchor.constraint(equalToConstant: 58),

            closeButton.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),

            recordingDot.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
            recordingDot.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            recordingDot.widthAnchor.constraint(equalToConstant: 8),
            recordingDot.heightAnchor.constraint(equalToConstant: 8),

            timerLabel.leadingAnchor.constraint(equalTo: recordingDot.trailingAnchor, constant: 8),
            timerLabel.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -16),
            timerLabel.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor)
        ])
    }

    private func configureToolRail() {
        toolRail.translatesAutoresizingMaskIntoConstraints = false
        toolRail.layer.cornerRadius = 24
        toolRail.layer.cornerCurve = .continuous
        toolRail.clipsToBounds = true
        addSubview(toolRail)

        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.tintColor = .white
        flashButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        flashButton.layer.cornerRadius = 22
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.textColor = .white
        zoomLabel.textAlignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)

        configureZoomButton(zoom1Button, title: "1x", action: #selector(zoom1Tapped))
        configureZoomButton(zoom2Button, title: "2x", action: #selector(zoom2Tapped))
        configureZoomButton(zoom3Button, title: "3x", action: #selector(zoom3Tapped))

        toolRail.contentView.addSubview(flashButton)
        toolRail.contentView.addSubview(zoomLabel)
        toolRail.contentView.addSubview(zoom1Button)
        toolRail.contentView.addSubview(zoom2Button)
        toolRail.contentView.addSubview(zoom3Button)

        NSLayoutConstraint.activate([
            toolRail.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            toolRail.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            toolRail.widthAnchor.constraint(equalToConstant: 58),
            toolRail.heightAnchor.constraint(equalToConstant: 240),

            flashButton.topAnchor.constraint(equalTo: toolRail.contentView.topAnchor, constant: 12),
            flashButton.centerXAnchor.constraint(equalTo: toolRail.contentView.centerXAnchor),
            flashButton.widthAnchor.constraint(equalToConstant: 44),
            flashButton.heightAnchor.constraint(equalToConstant: 44),

            zoomLabel.topAnchor.constraint(equalTo: flashButton.bottomAnchor, constant: 12),
            zoomLabel.centerXAnchor.constraint(equalTo: toolRail.contentView.centerXAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 48),

            zoom1Button.topAnchor.constraint(equalTo: zoomLabel.bottomAnchor, constant: 12),
            zoom1Button.centerXAnchor.constraint(equalTo: toolRail.contentView.centerXAnchor),
            zoom1Button.widthAnchor.constraint(equalToConstant: 42),
            zoom1Button.heightAnchor.constraint(equalToConstant: 34),

            zoom2Button.topAnchor.constraint(equalTo: zoom1Button.bottomAnchor, constant: 8),
            zoom2Button.centerXAnchor.constraint(equalTo: toolRail.contentView.centerXAnchor),
            zoom2Button.widthAnchor.constraint(equalToConstant: 42),
            zoom2Button.heightAnchor.constraint(equalToConstant: 34),

            zoom3Button.topAnchor.constraint(equalTo: zoom2Button.bottomAnchor, constant: 8),
            zoom3Button.centerXAnchor.constraint(equalTo: toolRail.contentView.centerXAnchor),
            zoom3Button.widthAnchor.constraint(equalToConstant: 42),
            zoom3Button.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func configureZoomButton(_ button: UIButton, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 17
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.layer.cornerRadius = 28
        bottomBar.layer.cornerCurve = .continuous
        bottomBar.clipsToBounds = true
        addSubview(bottomBar)

        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.tintColor = .black
        recordButton.backgroundColor = UIColor(red: 0, green: 0.90, blue: 0.46, alpha: 1)
        recordButton.setImage(UIImage(systemName: "record.circle"), for: .normal)
        recordButton.layer.cornerRadius = 34
        recordButton.layer.borderWidth = 4
        recordButton.layer.borderColor = UIColor(red: 0, green: 0.90, blue: 0.46, alpha: 1).cgColor
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        flipButton.translatesAutoresizingMaskIntoConstraints = false
        flipButton.tintColor = .white
        flipButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        flipButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        flipButton.layer.cornerRadius = 24
        flipButton.addTarget(self, action: #selector(flipTapped), for: .touchUpInside)

        bottomBar.contentView.addSubview(recordButton)
        bottomBar.contentView.addSubview(flipButton)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 18),
            bottomBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -18),
            bottomBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            bottomBar.heightAnchor.constraint(equalToConstant: 104),

            recordButton.centerXAnchor.constraint(equalTo: bottomBar.contentView.centerXAnchor),
            recordButton.centerYAnchor.constraint(equalTo: bottomBar.contentView.centerYAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 68),
            recordButton.heightAnchor.constraint(equalToConstant: 68),

            flipButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 42),
            flipButton.centerYAnchor.constraint(equalTo: bottomBar.contentView.centerYAnchor),
            flipButton.widthAnchor.constraint(equalToConstant: 48),
            flipButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureButtons() {
        setRecording(false)
        updateElapsedTime("00:00")
        updateZoom(1)
        updateFlash(mode: .off, isAvailable: true)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func recordTapped() {
        onRecord?()
    }

    @objc private func flipTapped() {
        onFlip?()
    }

    @objc private func flashTapped() {
        onFlash?()
    }

    private func updateZoomButtonSelection() {
        let buttons: [(UIButton, Double)] = [(zoom1Button, 1), (zoom2Button, 2), (zoom3Button, 3)]
        for (button, value) in buttons {
            let isSelected = abs(currentZoom - value) < 0.15
            button.backgroundColor = isSelected
                ? UIColor(red: 0, green: 0.90, blue: 0.46, alpha: 1)
                : UIColor.white.withAlphaComponent(0.12)
            button.setTitleColor(isSelected ? .black : .white, for: .normal)
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartZoom = currentZoom
        case .changed:
            let nextZoom = min(max(pinchStartZoom * Double(recognizer.scale), 1), 3)
            onZoomChanged?(nextZoom)
        default:
            break
        }
    }

    @objc private func zoom1Tapped() {
        onResetZoom?()
    }

    @objc private func zoom2Tapped() {
        onZoomChanged?(2)
    }

    @objc private func zoom3Tapped() {
        onZoomChanged?(3)
    }
}

private struct UploadPlaylistLookupSheet: View {
    let playlists: [UploadPlaylistOption]
    let selectedId: String?
    @Binding var query: String
    let onSelect: (String?) -> Void

    private var filtered: [UploadPlaylistOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return playlists }
        return playlists.filter { $0.title.lowercased().contains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 12) {
                    searchField
                    ScrollView {
                        VStack(spacing: 8) {
                            playlistButton(id: nil, title: "None - don't add to a playlist", subtitle: nil)
                            ForEach(filtered) { playlist in
                                playlistButton(id: playlist.id, title: playlist.title, subtitle: "\(playlist.count.items) items")
                            }
                            if filtered.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No matches for \"\(query)\"")
                                    .font(.system(size: 13))
                                    .foregroundStyle(C.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                    }
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func playlistButton(id: String?, title: String, subtitle: String?) -> some View {
        Button { onSelect(id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.textTertiary)
                    .frame(width: 26, height: 26)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(id == nil ? C.textTertiary : C.text)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(C.textTertiary)
                    }
                }
                Spacer()
                if id == selectedId || (id == nil && selectedId == nil) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(C.watch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(C.textTertiary)
            TextField("Search playlists...", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(C.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ThumbnailCropperSheet: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let onCancel: () -> Void
    let onApply: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("Position the image inside the frame.")
                        .font(.system(size: 13))
                        .foregroundStyle(C.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    GeometryReader { proxy in
                        let width = min(proxy.size.width, 360)
                        let height = width / aspectRatio
                        cropPreview(width: width, height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: aspectRatio < 1 ? 420 : 240)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Zoom")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(C.text)
                            Spacer()
                            Text("\(Int(zoom * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(C.textTertiary)
                        }
                        Slider(value: $zoom, in: 1...3)
                            .tint(C.watch)
                    }

                    Spacer(minLength: 0)
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Crop thumbnail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        onApply(croppedImage(viewport: cropViewportSize))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var cropViewportSize: CGSize {
        let width: CGFloat = aspectRatio < 1 ? 360 : 360
        return CGSize(width: width, height: width / aspectRatio)
    }

    private func cropPreview(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(C.watch, lineWidth: 2)
        }
    }

    private func croppedImage(viewport: CGSize) -> UIImage {
        guard let cgImage = normalizedImage(image).cgImage else { return image }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let baseScale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let effectiveScale = baseScale * zoom
        let displayedSize = CGSize(width: imageSize.width * effectiveScale, height: imageSize.height * effectiveScale)

        let visibleOriginX = (displayedSize.width - viewport.width) / 2 - offset.width
        let visibleOriginY = (displayedSize.height - viewport.height) / 2 - offset.height
        let cropX = max(0, min(imageSize.width - 1, visibleOriginX / effectiveScale))
        let cropY = max(0, min(imageSize.height - 1, visibleOriginY / effectiveScale))
        let cropWidth = min(imageSize.width - cropX, viewport.width / effectiveScale)
        let cropHeight = min(imageSize.height - cropY, viewport.height / effectiveScale)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight).integral

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedCGImage)
    }

    private func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private enum UploadFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

private extension View {
    func uploadTextFieldStyle() -> some View {
        self
            .padding(12)
            .background(C.elevated)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(C.text)
    }
}
