import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var contexts: UploadContextsResponse?
    @State private var selectedDestination: UploadContext?
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
    @State private var isExtractingFrames = false

    @State private var isLoading = true
    @State private var isPickingFile = false
    @State private var isUploading = false
    @State private var uploadProgress = 0.0
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var createdVideoId: String?
    @State private var showDestinationLookup = false
    @State private var showPlaylistLookup = false
    @State private var destinationQuery = ""
    @State private var playlistQuery = ""

    private let visibilityOptions = ["public", "unlisted", "private"]
    private var allDestinations: [UploadContext] { (contexts?.channels ?? []) + (contexts?.shows ?? []) }
    private var selectedPlaylist: UploadPlaylistOption? { playlists.first { $0.id == selectedPlaylistId } }
    private var selectedDestinationSubtitle: String {
        guard let selectedDestination else { return "Choose where this content will be published" }
        return selectedDestination.networkName ?? (selectedDestination.type == "show" ? "Show" : "Channel")
    }
    private var canSubmit: Bool {
        auth.isAuthenticated && fileURL != nil && thumbnail != nil && selectedDestination != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isUploading && !isExtractingFrames
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if !auth.isAuthenticated {
                authRequiredState
            } else if isLoading {
                ProgressView("Loading destinations...")
                    .tint(C.watch)
                    .foregroundStyle(C.text)
            } else if allDestinations.isEmpty {
                noDestinationState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        mediaSection
                        thumbnailSection
                        contentTypeSection
                        destinationSection
                        playlistSection
                        detailsSection
                        if contentType == "short" { linkSection }
                        uploadSection
                    }
                    .padding(C.pagePad)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if horizontalSizeClass == .compact, auth.isAuthenticated, !isLoading, !allDestinations.isEmpty {
                stickySubmitBar
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
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
        .task {
            await loadContexts()
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

    private var mediaSection: some View {
        section("Video File") {
            if fileURL != nil {
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
                        removeSelectedVideo()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(C.textTertiary)
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
                        Text("1 frame · \(orientation.capitalized)")
                            .font(.system(size: 12))
                            .foregroundStyle(C.watch)
                    }
                }
            } else {
                Button {
                    isPickingFile = true
                } label: {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(C.elevated)
                                .frame(width: 56, height: 56)
                            Image(systemName: "arrow.up.to.line.compact")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(C.textTertiary)
                        }
                        VStack(spacing: 4) {
                            Text("Tap to select a video")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(C.text.opacity(0.7))
                            Text("MP4, MOV, AVI, WebM")
                                .font(.system(size: 12))
                                .foregroundStyle(C.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                            .foregroundStyle(C.borderSubtle)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var thumbnailSection: some View {
        section("Thumbnail *") {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .aspectRatio(contentType == "short" ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: contentType == "short" ? 130 : .infinity)

                if let thumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(contentType == "short" ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
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

            Button {
                isPickingFile = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: thumbnail == nil ? "video.badge.plus" : "arrow.clockwise")
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thumbnail == nil ? "Pick from video" : "Replace video")
                            .font(.system(size: 13, weight: .semibold))
                        Text(thumbnail == nil ? "Select a video first" : "Extract a new frame")
                            .font(.system(size: 11))
                            .foregroundStyle(C.textTertiary)
                    }
                    Spacer()
                }
                .foregroundStyle(C.text.opacity(0.7))
                .padding(12)
                .background(C.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isUploading || isExtractingFrames)
        }
    }

    private var contentTypeSection: some View {
        section("Content Type") {
            Picker("Content Type", selection: $contentType) {
                Label("Video", systemImage: "play.rectangle").tag("video")
                Label("Short", systemImage: "iphone").tag("short")
            }
            .pickerStyle(.segmented)

            Text(contentType == "short" ? "Vertical short-form video, displayed in the Shorts feed." : "Standard video, displayed on your channel or show page.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
        }
    }

    private var destinationSection: some View {
        section("Destination") {
            Button {
                destinationQuery = ""
                showDestinationLookup = true
            } label: {
                lookupRow(
                    icon: selectedDestination?.type == "show" ? "play.tv" : "dot.radiowaves.left.and.right",
                    title: selectedDestination?.name ?? "Search channels and shows...",
                    subtitle: selectedDestinationSubtitle,
                    badge: selectedDestination?.type == "show" ? "Show" : "Channel",
                    badgeColor: selectedDestination?.type == "show" ? C.play : C.watch
                )
            }
            .buttonStyle(.plain)
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

    private func lookupRow(icon: String, title: String, subtitle: String, badge: String?, badgeColor: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(C.textTertiary)
                .frame(width: 20)
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

                if !linkVideos.isEmpty {
                    Picker("Video or clip", selection: Binding(
                        get: { linkedClipId ?? "" },
                        set: { linkedClipId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("None").tag("")
                        ForEach(linkVideos) { item in
                            Text(item.displayTitle).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if selectedDestination?.type == "show", !linkEpisodes.isEmpty {
                    Picker("Episode", selection: Binding(
                        get: { linkedEpisodeId ?? "" },
                        set: { linkedEpisodeId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("None").tag("")
                        ForEach(linkEpisodes) { item in
                            Text(item.displayTitle).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
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

            if let createdVideoId {
                NavigationLink(value: AppRoute.video(createdVideoId)) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Open uploaded video")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
            }

            submitButton
        }
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
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(C.bg.opacity(0.97))
        .overlay(Rectangle().fill(C.borderSubtle).frame(height: 1), alignment: .top)
    }

    private var submitButton: some View {
        Button {
            Task { await submitUpload() }
        } label: {
            HStack(spacing: 8) {
                if isUploading || isExtractingFrames {
                    ProgressView().tint(.black)
                } else if canSubmit {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(submitTitle)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(C.watch)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(canSubmit || isUploading || isExtractingFrames ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private var submitTitle: String {
        if isUploading { return statusText.isEmpty ? "Uploading..." : statusText }
        if isExtractingFrames { return "Preparing frames..." }
        if fileURL == nil { return "Select a video to start" }
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
        .padding(16)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadContexts() async {
        guard auth.isAuthenticated else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.fetchUploadContexts()
            contexts = response
            selectedDestination = response.channels.first ?? response.shows.first
            await loadDependentOptions()
        } catch {
            errorText = error.localizedDescription
        }
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
            errorText = nil
            isExtractingFrames = true

            Task { await inspectVideo(tempURL) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func inspectVideo(_ url: URL) async {
        defer {
            Task { @MainActor in isExtractingFrames = false }
        }

        let asset = AVAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let detectedOrientation = abs(size.height) > abs(size.width) ? "vertical" : "horizontal"

        await MainActor.run {
            orientation = detectedOrientation
            if contentType != "short", detectedOrientation == "vertical" {
                contentType = "short"
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
            await MainActor.run {
                thumbnail = Image(decorative: cgImage, scale: 1)
            }
        }
    }

    private func removeSelectedVideo() {
        guard !isUploading else { return }
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        fileName = ""
        fileSize = 0
        orientation = "horizontal"
        thumbnail = nil
        isExtractingFrames = false
        createdVideoId = nil
        uploadProgress = 0
        statusText = ""
        errorText = nil
    }

    private func submitUpload() async {
        guard let fileURL, let selectedDestination else { return }
        isUploading = true
        errorText = nil
        createdVideoId = nil
        uploadProgress = 0
        statusText = "Preparing upload..."
        defer { isUploading = false }

        do {
            let oneGb: Int64 = 1024 * 1024 * 1024
            if fileSize > oneGb {
                throw UploadFailure.message("Video files must be under 1 GB. Please compress your video before uploading.")
            }

            let channelId = selectedDestination.type == "channel" ? selectedDestination.id : nil
            let cf = try await APIClient.shared.createCfStreamUpload(fileSize: fileSize, channelId: channelId)
            if let limit = cf.uploadLimitBytes, fileSize > Int64(limit) {
                let mb = Int64(limit) / 1024 / 1024
                throw UploadFailure.message("Video exceeds the \(mb) MB upload limit for this channel.")
            }
            guard let uploadURL = URL(string: cf.uploadUrl) else {
                throw APIError.badURL(cf.uploadUrl)
            }

            statusText = "Uploading video..."
            try await APIClient.shared.uploadToTus(uploadUrl: uploadURL, fileURL: fileURL, fileSize: fileSize) { pct in
                await MainActor.run {
                    uploadProgress = pct * 0.68
                    statusText = "Uploading video... \(Int(pct * 100))%"
                }
            }

            uploadProgress = 0.85
            statusText = "Saving..."
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
                thumbnailUrl: cloudflareThumbnailUrl(streamId: cf.streamId)
            )
            createdVideoId = video.id
            uploadProgress = 0.85
            statusText = "Transcoding..."
            let isReady = await pollTranscode(videoId: video.id)
            let videoTitle = video.title ?? title
            try? await APIClient.shared.createNotification(
                type: "upload_complete",
                title: isReady ? "Video ready" : "Upload complete",
                message: isReady
                    ? "\"\(videoTitle)\" finished transcoding and is ready to watch."
                    : "\"\(videoTitle)\" uploaded and is still processing.",
                linkUrl: "/watch/\(video.id)"
            )
            statusText = isReady ? "Video ready" : "Upload complete - still processing"
        } catch {
            uploadProgress = 0
            errorText = friendlyError(error)
            statusText = errorText ?? "Upload failed"
        }
    }

    private func pollTranscode(videoId: String) async -> Bool {
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            do {
                let status = try await APIClient.shared.fetchUploadStreamStatus(videoId: videoId)
                let transcodeProgress = min(99, status.pct)
                uploadProgress = min(0.99, 0.85 + (Double(transcodeProgress) / 100 * 0.14))
                statusText = status.ready ? "Video ready" : "Transcoding... \(transcodeProgress)%"
                if status.ready {
                    uploadProgress = 1
                    return true
                }
            } catch {
                // Network blips should not fail the completed upload.
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        return false
    }

    private func cloudflareThumbnailUrl(streamId: String) -> String {
        "https://videodelivery.net/\(streamId)/thumbnails/thumbnail.jpg?time=1s"
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
        AsyncImage(url: C.mediaURL(destination.avatarUrl)) { image in
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
