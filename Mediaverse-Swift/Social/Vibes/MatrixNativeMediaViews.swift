import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MatrixNativeRichComposer: View {
    let roomID: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let mentionMembers: [MatrixNativeWaveMember]
    let sendText: ([MatrixNativeMentionTarget]) -> Void
    let sendAttachments: ([MatrixNativeUpload], String?) -> Void
    let sendPoll: (String, [String]) -> Void
    let sendSticker: (MatrixNativeUpload) -> Void

    @State private var attachments: [MatrixNativeUpload] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showStickerPicker = false
    @State private var showFileImporter = false
    @State private var showVideoCamera = false
    @State private var showPollComposer = false
    @State private var showVoiceRecorder = false
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var selectedMentions: [MatrixNativeMentionTarget] = []

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var mentionSuggestions: [MatrixNativeMentionTarget] {
        guard let query = MatrixNativeMentionComposer.query(in: text) else {
            return []
        }
        let needle = query.lowercased()
        return mentionMembers
            .filter { !$0.isService && $0.state == .joined }
            .map {
                MatrixNativeMentionTarget(
                    userID: $0.userID,
                    displayName: $0.displayName
                )
            }
            .filter {
                needle.isEmpty
                    || $0.displayName.lowercased().contains(needle)
                    || $0.userID.lowercased().contains(needle)
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !mentionSuggestions.isEmpty {
                MatrixNativeMentionSuggestions(
                    suggestions: mentionSuggestions,
                    select: selectMention
                )
                .padding(.horizontal, C.pagePad)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(4)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            MatrixNativeDraftAttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                }
                .accessibilityLabel("Selected attachments")
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photos and videos", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        showVideoCamera = true
                    } label: {
                        Label("Record video", systemImage: "video")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button {
                        showVoiceRecorder = true
                    } label: {
                        Label("Voice message", systemImage: "waveform")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("File", systemImage: "doc")
                    }
                    Button {
                        showPollComposer = true
                    } label: {
                        Label("Poll", systemImage: "chart.bar.xaxis")
                    }
                    Button {
                        showStickerPicker = true
                    } label: {
                        Label("Sticker", systemImage: "face.smiling")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.bold())
                        .foregroundStyle(C.watch)
                        .frame(width: 44, height: 44)
                        .background(C.elevated, in: Circle())
                        .overlay(Circle().stroke(C.borderSubtle))
                }
                .accessibilityLabel("Add attachment")

                TextField("Message this Wave", text: $text, axis: .vertical)
                    .focused(isFocused)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(C.elevated, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.borderSubtle))
                    .accessibilityLabel("Message this Wave")

                Button(action: commit) {
                    Group {
                        if isPreparing {
                            ProgressView().tint(C.bg)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.headline.bold())
                        }
                    }
                    .foregroundStyle(C.bg)
                    .frame(width: 44, height: 44)
                    .background(C.watch, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isPreparing)
                .opacity(canSend && !isPreparing ? 1 : 0.45)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(C.borderSubtle) }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: MatrixNativeMediaPolicy.maximumAttachmentCount,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: { result in
                Task { await importFiles(result) }
            }
        )
        .sheet(isPresented: $showVideoCamera) {
            MatrixNativeVideoCapturePicker { result in
                showVideoCamera = false
                if case let .success(url) = result {
                    Task { await addCapturedVideo(url) }
                } else if case let .failure(error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showVoiceRecorder) {
            MatrixNativeVoiceRecorderSheet { upload in
                if let upload {
                    appendSafely([upload])
                }
                showVoiceRecorder = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPollComposer) {
            MatrixNativePollComposerSheet { question, options in
                sendPoll(question, options)
                showPollComposer = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStickerPicker) {
            MatrixNativeApprovedStickerPicker { upload in
                sendSticker(upload)
                showStickerPicker = false
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await preparePhotos(items) }
        }
        .alert("Attachment unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func commit() {
        if attachments.isEmpty {
            let active = MatrixNativeMentionComposer.activeTargets(
                in: text,
                selected: selectedMentions
            )
            sendText(active)
            selectedMentions = []
        } else {
            let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
            sendAttachments(attachments, caption.isEmpty ? nil : caption)
            attachments = []
            text = ""
            selectedMentions = []
        }
    }

    private func selectMention(_ target: MatrixNativeMentionTarget) {
        text = MatrixNativeMentionComposer.inserting(target, into: text)
        selectedMentions.removeAll { $0.userID == target.userID }
        selectedMentions.append(target)
        isFocused.wrappedValue = true
    }

    @MainActor
    private func preparePhotos(_ items: [PhotosPickerItem]) async {
        isPreparing = true
        defer {
            isPreparing = false
            selectedPhotoItems = []
        }
        do {
            var prepared: [MatrixNativeUpload] = []
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
                let contentType = item.supportedContentTypes.first {
                    $0.conforms(to: .image) || $0.conforms(to: .movie)
                }
                let mime = contentType?.preferredMIMEType
                    ?? (contentType?.conforms(to: .movie) == true ? "video/mp4" : "image/jpeg")
                let kind: MatrixNativeAttachmentKind =
                    contentType?.conforms(to: .movie) == true ? .video : .image
                let image = kind == .image ? UIImage(data: data) : nil
                let fileExtension =
                    contentType?.preferredFilenameExtension ?? (kind == .video ? "mp4" : "jpg")
                let duration = kind == .video
                    ? try await derivedVideoDuration(
                        from: data,
                        fileExtension: fileExtension
                    )
                    : nil
                prepared.append(MatrixNativeUpload(
                    kind: kind,
                    data: data,
                    filename: "vibes-\(index + 1).\(fileExtension)",
                    mimeType: mime,
                    width: image.map { UInt64(max(1, $0.size.width * $0.scale)) },
                    height: image.map { UInt64(max(1, $0.size.height * $0.scale)) },
                    duration: duration
                ))
            }
            appendSafely(prepared)
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func importFiles(_ result: Result<[URL], Error>) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let urls = try result.get()
            var prepared: [MatrixNativeUpload] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = UTType(filenameExtension: url.pathExtension)
                let mime = type?.preferredMIMEType ?? "application/octet-stream"
                let kind: MatrixNativeAttachmentKind
                if type?.conforms(to: .image) == true {
                    kind = .image
                } else if type?.conforms(to: .audio) == true {
                    kind = .audio
                } else if type?.conforms(to: .movie) == true {
                    kind = .video
                } else {
                    kind = .file
                }
                let declaredSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let conservativeLimit: UInt64
                switch kind {
                case .image, .sticker:
                    conservativeLimit = MatrixNativeMediaPolicy.maximumImageBytes
                case .audio, .voice:
                    conservativeLimit = MatrixNativeMediaPolicy.maximumAudioBytes
                case .video:
                    conservativeLimit = MatrixNativeMediaPolicy.maximumVideoBytes
                case .file:
                    conservativeLimit = MatrixNativeMediaPolicy.maximumFileBytes
                }
                guard declaredSize > 0, UInt64(declaredSize) <= conservativeLimit else {
                    throw MatrixNativeMediaError.attachmentTooLarge(limitBytes: conservativeLimit)
                }
                let data = try Data(contentsOf: url)
                let image = kind == .image ? UIImage(data: data) : nil
                let duration = kind == .video
                    ? try await derivedVideoDuration(from: url)
                    : nil
                prepared.append(MatrixNativeUpload(
                    kind: kind,
                    data: data,
                    filename: String(url.lastPathComponent.prefix(255)),
                    mimeType: mime,
                    width: image.map { UInt64(max(1, $0.size.width * $0.scale)) },
                    height: image.map { UInt64(max(1, $0.size.height * $0.scale)) },
                    duration: duration
                ))
            }
            appendSafely(prepared)
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    @MainActor
    private func addCapturedVideo(_ url: URL) async {
        isPreparing = true
        defer {
            isPreparing = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let declaredSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard declaredSize > 0,
                  UInt64(declaredSize) <= MatrixNativeMediaPolicy.maximumVideoBytes else {
                throw MatrixNativeMediaError.attachmentTooLarge(
                    limitBytes: MatrixNativeMediaPolicy.maximumVideoBytes
                )
            }
            let data = try Data(contentsOf: url)
            let duration = try await derivedVideoDuration(from: url)
            let upload = MatrixNativeUpload(
                kind: .video,
                data: data,
                filename: "vibes-video.mov",
                mimeType: "video/quicktime",
                duration: duration
            )
            appendSafely([upload])
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }

    private func derivedVideoDuration(
        from data: Data,
        fileExtension: String
    ) async throws -> TimeInterval {
        let safeExtension = String(
            fileExtension
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
                .prefix(8)
        )
        guard !safeExtension.isEmpty else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("westreem-video-\(UUID().uuidString)")
            .appendingPathExtension(safeExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return try await derivedVideoDuration(from: url)
    }

    private func derivedVideoDuration(from url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard MatrixNativeMediaSafetyContract.acceptsDuration(
            duration,
            for: .video
        ) else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        return duration
    }

    @MainActor
    private func appendSafely(_ newUploads: [MatrixNativeUpload]) {
        do {
            let combined = attachments + newUploads
            try MatrixNativeMediaPolicy.validate(
                combined,
                serverMaximumBytes: MatrixNativeMediaPolicy.maximumVideoBytes
            )
            attachments = combined
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
    }
}

struct MatrixNativeMentionSuggestions: View {
    let suggestions: [MatrixNativeMentionTarget]
    let select: (MatrixNativeMentionTarget) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { target in
                    Button {
                        select(target)
                    } label: {
                        HStack(spacing: 8) {
                            MatrixNativeAvatar(name: target.displayName, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayName)
                                    .font(.caption.bold())
                                    .foregroundStyle(C.text)
                                    .lineLimit(1)
                                Text(target.userID)
                                    .font(.caption2)
                                    .foregroundStyle(C.textMuted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            C.elevated,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(C.watch.opacity(0.35))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mention \(target.displayName)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Wave member mention suggestions")
    }
}

/// Matrix stickers are deliberately sourced only from the governed Westreem
/// registry. The authenticated API re-resolves approval and verifies the
/// server-side SHA-256 for every preview and selection; the client then
/// validates the declared type and bytes before creating an `m.sticker`.
private struct MatrixNativeApprovedStickerPicker: View {
    let choose: (MatrixNativeUpload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var packs: [MatrixNativeApprovedStickerPack] = []
    @State private var selectedPackID: String?
    @State private var imageDataByAssetID: [String: Data] = [:]
    @State private var failedPreviewIDs: Set<String> = []
    @State private var isLoading = true
    @State private var selectingAssetID: String?
    @State private var errorMessage: String?

    private var selectedPack: MatrixNativeApprovedStickerPack? {
        packs.first { $0.id == selectedPackID } ?? packs.first
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 4
    )

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading approved stickers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if packs.isEmpty {
                    ContentUnavailableView {
                        Label("No approved stickers", systemImage: "face.smiling")
                    } description: {
                        Text("Approved WeStreem sticker packs will appear here.")
                    } actions: {
                        Button("Try Again") {
                            Task { await loadPacks() }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if packs.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(packs) { pack in
                                            Button {
                                                selectedPackID = pack.id
                                            } label: {
                                                Text(pack.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(
                                                        selectedPack?.id == pack.id ? C.bg : .primary
                                                    )
                                                    .padding(.horizontal, 13)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        selectedPack?.id == pack.id
                                                            ? C.watch
                                                            : C.elevated,
                                                        in: Capsule()
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityAddTraits(
                                                selectedPack?.id == pack.id ? .isSelected : []
                                            )
                                        }
                                    }
                                    .padding(.horizontal, C.pagePad)
                                }
                            }

                            if let selectedPack {
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(selectedPack.assets) { asset in
                                        stickerButton(asset)
                                    }
                                }
                                .padding(.horizontal, C.pagePad)
                                .id("\(selectedPack.id):\(selectedPack.version)")
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Approved WeStreem sticker packs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
            }
            .alert("Sticker unavailable", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard packs.isEmpty else { return }
                await loadPacks()
            }
        }
    }

    @ViewBuilder
    private func stickerButton(_ asset: MatrixNativeApprovedStickerAsset) -> some View {
        Button {
            Task { await select(asset) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(C.elevated)

                if let data = imageDataByAssetID[asset.id],
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(9)
                } else if failedPreviewIDs.contains(asset.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }

                if selectingAssetID == asset.id {
                    Color.black.opacity(0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(C.borderSubtle)
            )
        }
        .buttonStyle(.plain)
        .disabled(selectingAssetID != nil || failedPreviewIDs.contains(asset.id))
        .accessibilityLabel("Send \(asset.label) sticker")
        .task(id: asset.id) {
            await loadPreview(asset)
        }
    }

    @MainActor
    private func loadPacks() async {
        isLoading = true
        errorMessage = nil
        do {
            let approved = try await APIClient.shared.matrixApprovedStickerPacks()
                .filter { !$0.assets.isEmpty }
            packs = approved
            if !approved.contains(where: { $0.id == selectedPackID }) {
                selectedPackID = approved.first?.id
            }
        } catch {
            packs = []
            errorMessage = "Approved sticker packs could not be loaded. Check your connection and try again."
        }
        isLoading = false
    }

    @MainActor
    private func loadPreview(_ asset: MatrixNativeApprovedStickerAsset) async {
        guard
            imageDataByAssetID[asset.id] == nil,
            !failedPreviewIDs.contains(asset.id)
        else {
            return
        }
        do {
            let data = try await APIClient.shared.matrixApprovedStickerData(asset: asset)
            guard UIImage(data: data) != nil else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            imageDataByAssetID[asset.id] = data
        } catch is CancellationError {
            return
        } catch {
            failedPreviewIDs.insert(asset.id)
        }
    }

    @MainActor
    private func select(_ asset: MatrixNativeApprovedStickerAsset) async {
        guard selectingAssetID == nil else { return }
        selectingAssetID = asset.id
        defer { selectingAssetID = nil }
        do {
            let data: Data
            if let cached = imageDataByAssetID[asset.id] {
                data = cached
            } else {
                data = try await APIClient.shared.matrixApprovedStickerData(asset: asset)
            }
            guard UIImage(data: data) != nil else {
                throw MatrixNativeMediaError.invalidAttachment
            }
            let upload = MatrixNativeUpload(
                kind: .sticker,
                data: data,
                filename: MatrixNativeApprovedStickerContract.filename(for: asset),
                mimeType: asset.mimeType,
                width: asset.width.map(UInt64.init),
                height: asset.height.map(UInt64.init)
            )
            try MatrixNativeMediaPolicy.validate(
                [upload],
                serverMaximumBytes: UInt64(MatrixNativeApprovedStickerContract.maximumBytes)
            )
            choose(upload)
            dismiss()
        } catch {
            errorMessage = "This approved sticker could not be verified or sent. Please try again."
        }
    }
}

private struct MatrixNativeDraftAttachmentChip: View {
    let attachment: MatrixNativeUpload
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: MatrixNativeMediaCopy.icon(for: attachment.kind))
                .foregroundStyle(C.watch)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).lineLimit(1)
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(attachment.data.count),
                    countStyle: .file
                ))
                .font(.caption2)
                .foregroundStyle(C.textMuted)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(C.textMuted)
            }
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(C.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(C.elevated, in: Capsule())
        .overlay(Capsule().stroke(C.borderSubtle))
        .frame(maxWidth: 240)
    }
}

struct MatrixNativePollCard: View {
    let poll: MatrixNativePollDescriptor
    let vote: (String) -> Void

    private var totalVotes: Int {
        poll.options.reduce(0) { $0 + $1.voteCount }
    }

    private var showsResults: Bool {
        MatrixNativePollVisibilityContract.showsResults(
            isDisclosed: poll.isDisclosed,
            hasEnded: poll.hasEnded
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question)
                .font(.subheadline.bold())
                .foregroundStyle(C.text)
            ForEach(poll.options) { option in
                Button {
                    guard !poll.hasEnded else { return }
                    vote(option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(option.text).lineLimit(2)
                            Spacer()
                            if showsResults, totalVotes > 0 {
                                Text("\(Int((Double(option.voteCount) / Double(totalVotes)) * 100))%")
                                    .monospacedDigit()
                            }
                        }
                        if showsResults {
                            GeometryReader { geometry in
                                let fraction = totalVotes == 0
                                    ? 0
                                    : Double(option.voteCount) / Double(totalVotes)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(C.borderSubtle)
                                    Capsule()
                                        .fill(C.watch)
                                        .frame(width: geometry.size.width * fraction)
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(C.text)
                    .padding(9)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(poll.hasEnded)
            }
            Text(
                showsResults
                    ? (poll.hasEnded ? "Poll ended · \(totalVotes) votes" : "\(totalVotes) votes")
                    : "Results hidden until the poll ends"
            )
                .font(.caption2)
                .foregroundStyle(C.textMuted)
        }
        .padding(11)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        .accessibilityElement(children: .contain)
    }
}

struct MatrixNativeLinkPreviewCard: View {
    let messageBody: String
    let enabled: Bool

    @State private var preview: MatrixNativeLinkPreviewMetadata?

    private var link: String? {
        enabled
            ? MatrixNativeLinkPreviewContract.firstPublicHTTPURL(
                in: messageBody
            )
            : nil
    }

    var body: some View {
        Group {
            if let preview,
               let destination = MatrixNativeLinkPreviewContract.safePublicHTTPURL(
                   preview.finalURL
               ) {
                Link(destination: destination) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preview.domain)
                                .font(.caption2)
                                .foregroundStyle(C.textTertiary)
                                .lineLimit(1)
                            Text(preview.title?.isEmpty == false
                                ? preview.title!
                                : preview.domain)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(C.text)
                                .lineLimit(1)
                            if let description = preview.description,
                               !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(C.textMuted)
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let imageURL = proxyURL(for: preview.imageURL) {
                            AsyncImage(url: imageURL) { phase in
                                if case let .success(image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    C.elevated
                                }
                            }
                            .frame(width: 104, height: 108)
                            .clipped()
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 108)
                    .background(C.surface.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(C.borderSubtle)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Open link preview: \(preview.title ?? preview.domain)"
                )
            }
        }
        .task(id: link) {
            preview = nil
            if let link { await load(link) }
        }
    }

    private func proxyURL(for source: String?) -> URL? {
        guard let source,
              MatrixNativeLinkPreviewContract.safePublicHTTPURL(source) != nil,
              var components = URLComponents(
                  string: C.baseURL + MatrixNativeLinkPreviewContract.imageProxyPath
              )
        else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "url", value: source)]
        return components.url
    }

    private func load(_ link: String) async {
        do {
            preview = try await APIClient.shared.matrixLinkPreview(for: link)
        } catch {
            preview = nil
        }
    }
}

struct MatrixNativeMediaStrip: View {
    let roomID: String
    let media: [MatrixNativeMediaDescriptor]
    @State private var selectedMedia: MatrixNativeMediaDescriptor?

    var body: some View {
        Group {
            if media.count == 1, let item = media.first {
                MatrixNativeRemoteMediaThumbnail(roomID: roomID, media: item)
                    .onTapGesture { selectedMedia = item }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                    ],
                    spacing: 4
                ) {
                    ForEach(media) { item in
                        MatrixNativeRemoteMediaThumbnail(roomID: roomID, media: item)
                            .onTapGesture { selectedMedia = item }
                    }
                }
            }
        }
        .sheet(item: $selectedMedia) { item in
            MatrixNativeMediaViewer(roomID: roomID, media: item)
        }
    }
}

private struct MatrixNativeRemoteMediaThumbnail: View {
    let roomID: String
    let media: MatrixNativeMediaDescriptor
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var image: UIImage?
    @State private var state: LoadState = .idle

    private enum LoadState { case idle, loading, ready, unavailable }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(C.elevated)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                VStack(spacing: 7) {
                    if state == .loading {
                        ProgressView().tint(C.watch)
                    } else {
                        Image(systemName: MatrixNativeMediaCopy.icon(for: media.kind))
                            .font(.title2)
                            .foregroundStyle(state == .unavailable ? Color.red : C.watch)
                    }
                    Text(media.filename)
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
            }
            if media.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: media.kind == .sticker ? 150 : 190)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
        .contentShape(Rectangle())
        .accessibilityLabel("\(MatrixNativeMediaCopy.label(for: media.kind)): \(media.filename)")
        .task(id: media.id) {
            guard media.kind == .image || media.kind == .sticker else { return }
            state = .loading
            do {
                let data = try await matrixSession.mediaData(roomID: roomID, media: media)
                guard let decoded = UIImage(data: data) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
                image = decoded
                state = .ready
            } catch {
                state = .unavailable
            }
        }
    }
}

private struct MatrixNativeMediaViewer: View {
    let roomID: String
    let media: MatrixNativeMediaDescriptor
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var localFileURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading securely…").tint(C.watch)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Attachment unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    }
                } else if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else if let player, media.kind == .audio || media.kind == .voice {
                    MatrixNativeAudioPlayback(player: player, title: media.filename)
                } else if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                } else if let localFileURL {
                    VStack(spacing: 18) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(C.watch)
                        Text(media.filename).foregroundStyle(C.text)
                        ShareLink(item: localFileURL) {
                            Label("Open or share file", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(C.watch)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(media.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: media.id) { await load() }
        .onDisappear {
            player?.pause()
            if let localFileURL { try? FileManager.default.removeItem(at: localFileURL) }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            let data = try await matrixSession.mediaData(roomID: roomID, media: media)
            if media.kind == .image || media.kind == .sticker {
                guard let decoded = UIImage(data: data) else {
                    throw MatrixNativeMediaError.invalidAttachment
                }
                image = decoded
            } else {
                let safeName = MatrixNativeMediaCopy.safeFilename(media.filename)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("matrix-\(UUID().uuidString)-\(safeName)")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                localFileURL = url
                if [.audio, .voice, .video].contains(media.kind) {
                    player = AVPlayer(url: url)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
        isLoading = false
    }
}

private struct MatrixNativeAudioPlayback: View {
    let player: AVPlayer
    let title: String
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 78))
                .foregroundStyle(C.watch)
            Text(title)
                .font(.headline)
                .foregroundStyle(C.text)
                .lineLimit(2)
            Button {
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
        }
        .onDisappear { player.pause() }
        .accessibilityElement(children: .contain)
    }
}

private struct MatrixNativePollComposerSheet: View {
    let publish: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask the Wave", text: $question, axis: .vertical)
                }
                Section("Answers") {
                    ForEach(options.indices, id: \.self) { index in
                        TextField("Option \(index + 1)", text: $options[index])
                    }
                    if options.count < 10 {
                        Button("Add answer") { options.append("") }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg)
            .navigationTitle("Create Poll")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        do {
                            let validated = try MatrixNativeMediaPolicy.validatePoll(
                                question: question,
                                options: options
                            )
                            publish(validated.0, validated.1)
                        } catch {
                            errorMessage = MatrixNativeMediaCopy.message(for: error)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private final class MatrixNativeVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, requesting, recording, ready, denied, failed }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    private(set) var fileURL: URL?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async {
        state = .requesting
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("matrix-voice-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw MatrixNativeMediaError.mediaUnavailable }
            self.recorder = recorder
            fileURL = url
            elapsed = 0
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    if self.elapsed >= MatrixNativeMediaPolicy.maximumVoiceDuration { self.finish() }
                }
            }
        } catch {
            state = .failed
        }
    }

    func finish() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = elapsed >= 1 ? .ready : .failed
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        elapsed = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func makeUpload() throws -> MatrixNativeUpload {
        guard state == .ready, let fileURL else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        return MatrixNativeUpload(
            kind: .voice,
            data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            filename: "voice-message.m4a",
            mimeType: "audio/m4a",
            duration: elapsed
        )
    }
}

private struct MatrixNativeVoiceRecorderSheet: View {
    let completion: (MatrixNativeUpload?) -> Void
    @StateObject private var recorder = MatrixNativeVoiceRecorder()

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(C.borderSubtle).frame(width: 42, height: 5)
            Text("Voice Message").font(.title3.bold()).foregroundStyle(C.text)
            Image(systemName: recorder.state == .recording ? "waveform.circle.fill" : "mic.circle")
                .font(.system(size: 72))
                .foregroundStyle(recorder.state == .recording ? Color.red : C.watch)
                .symbolEffect(.pulse, isActive: recorder.state == .recording)
            Text(MatrixNativeMediaCopy.duration(recorder.elapsed))
                .font(.title2.monospacedDigit())
                .foregroundStyle(C.text)
            HStack(spacing: 14) {
                Button("Cancel") {
                    recorder.discard()
                    completion(nil)
                }
                .buttonStyle(.bordered)
                if recorder.state == .recording {
                    Button("Finish") { recorder.finish() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if recorder.state == .ready {
                    Button("Attach") {
                        do {
                            completion(try recorder.makeUpload())
                        } catch {
                            completion(nil)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                } else {
                    Button("Record") { Task { await recorder.start() } }
                        .buttonStyle(.borderedProminent)
                        .tint(C.watch)
                }
            }
            if recorder.state == .denied {
                Text("Microphone access is required to record a voice message.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if recorder.state == .failed {
                Text("Record at least one second, then try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }
}

private struct MatrixNativeVideoCapturePicker: UIViewControllerRepresentable {
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = MatrixNativeMediaPolicy.maximumVideoDuration
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result<URL, Error>) -> Void

        init(completion: @escaping (Result<URL, Error>) -> Void) {
            self.completion = completion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let url = info[.mediaURL] as? URL else {
                completion(.failure(MatrixNativeMediaError.invalidAttachment))
                return
            }
            completion(.success(url))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(.failure(CancellationError()))
        }
    }
}

enum MatrixNativeMediaCopy {
    static func summary(for uploads: [MatrixNativeUpload]) -> String {
        if uploads.count == 1, let upload = uploads.first {
            return "\(label(for: upload.kind)) · \(upload.filename)"
        }
        return "\(uploads.count) attachments"
    }

    static func icon(for kind: MatrixNativeAttachmentKind) -> String {
        switch kind {
        case .image: "photo"
        case .audio, .voice: "waveform"
        case .video: "video"
        case .file: "doc"
        case .sticker: "face.smiling"
        }
    }

    static func label(for kind: MatrixNativeAttachmentKind) -> String {
        switch kind {
        case .image: "Photo"
        case .audio: "Audio"
        case .voice: "Voice message"
        case .video: "Video message"
        case .file: "File"
        case .sticker: "Sticker"
        }
    }

    static func message(for error: Error) -> String {
        if let localized = error as? MatrixNativeMediaError {
            return localized.errorDescription ?? "The attachment is unavailable."
        }
        if error is CancellationError { return "The attachment selection was cancelled." }
        return "The attachment could not be prepared or sent. Check your connection and try again."
    }

    static func isRecoverable(_ error: Error) -> Bool {
        guard let mediaError = error as? MatrixNativeMediaError else { return true }
        switch mediaError {
        case .encryptedMediaUnavailable, .invalidAttachment, .unsupportedAttachment,
             .attachmentTooLarge, .totalTooLarge, .tooManyAttachments,
             .emptyPoll, .invalidPollOptions:
            return false
        case .mediaUnavailable:
            return true
        }
    }

    static func safeFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = filename.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let value = String(sanitized).prefix(120)
        return value.isEmpty ? "attachment" : String(value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
