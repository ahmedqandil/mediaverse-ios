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
    let sendPoll: (String, [String], UInt64, Bool) -> Void
    let sendSticker: (MatrixNativeUpload) -> Void
    var allowsPollsAndStickers = true

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
                    if allowsPollsAndStickers {
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

                Button(action: primaryComposerAction) {
                    Group {
                        if isPreparing {
                            ProgressView().tint(C.bg)
                        } else {
                            Image(systemName: canSend ? "arrow.up" : "mic.fill")
                                .font(.headline.bold())
                        }
                    }
                    .foregroundStyle(C.bg)
                    .frame(width: 44, height: 44)
                    .background(canSend ? C.watch : C.elevated, in: Circle())
                    .overlay(Circle().stroke(canSend ? Color.clear : C.borderSubtle))
                }
                .buttonStyle(.plain)
                .disabled(isPreparing)
                .opacity(isPreparing ? 0.45 : 1)
                .accessibilityLabel(canSend ? "Send message" : "Record voice message")
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
                    sendAttachments([upload], nil)
                }
                showVoiceRecorder = false
            }
            .presentationDetents([.height(360), .medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPollComposer) {
            MatrixNativePollComposerSheet { question, options, maximum, disclosed in
                sendPoll(question, options, maximum, disclosed)
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

    private func primaryComposerAction() {
        if canSend {
            commit()
        } else {
            showVoiceRecorder = true
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
                let fileExtension =
                    contentType?.preferredFilenameExtension ?? (kind == .video ? "mp4" : "jpg")
                let duration = kind == .video
                    ? try await derivedVideoDuration(
                        from: data,
                        fileExtension: fileExtension
                    )
                    : nil

                // Image compression: mirror web behaviour — images >2 MB are downscaled
                // to max 2048 px on the long edge and re-encoded as JPEG at 0.85 quality.
                // Preserves originals when compression produces a larger file.
                let (finalData, finalMime, finalExt, finalWidth, finalHeight): (Data, String, String, UInt64?, UInt64?)
                if kind == .image, let compressed = Self.compressImage(data: data) {
                    finalData    = compressed.data
                    finalMime    = "image/jpeg"
                    finalExt     = "jpg"
                    finalWidth   = UInt64(compressed.width)
                    finalHeight  = UInt64(compressed.height)
                } else {
                    let img = kind == .image ? UIImage(data: data) : nil
                    finalData    = data
                    finalMime    = mime
                    finalExt     = fileExtension
                    finalWidth   = img.map { UInt64(max(1, $0.size.width  * $0.scale)) }
                    finalHeight  = img.map { UInt64(max(1, $0.size.height * $0.scale)) }
                }
                prepared.append(MatrixNativeUpload(
                    kind: kind,
                    data: finalData,
                    filename: "vibes-\(index + 1).\(finalExt)",
                    mimeType: finalMime,
                    width: finalWidth,
                    height: finalHeight,
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

    /// Compress an image if it exceeds the 2 MB threshold.
    /// - Returns a tuple with the compressed JPEG data and pixel dimensions,
    ///   or nil if compression is not needed or fails (caller keeps original).
    /// Mirrors the web canvas-based approach: max 2048 px long edge, JPEG 0.85 quality.
    private static func compressImage(
        data: Data
    ) -> (data: Data, width: Int, height: Int)? {
        let compressThreshold = 2 * 1024 * 1024  // 2 MB
        guard data.count > compressThreshold, let source = UIImage(data: data) else { return nil }

        let maxPx: CGFloat = 2048
        let originalWidth  = source.size.width  * source.scale
        let originalHeight = source.size.height * source.scale
        let scale = min(1.0, maxPx / max(originalWidth, originalHeight))
        let targetWidth  = max(1, Int(originalWidth  * scale))
        let targetHeight = max(1, Int(originalHeight * scale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetWidth, height: targetHeight),
            format: format
        )
        let rendered = renderer.image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.85),
              jpeg.count < data.count else { return nil }
        return (jpeg, targetWidth, targetHeight)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(MatrixNativeMediaCopy.displayTitle(for: attachment)).lineLimit(1)
                Text(MatrixNativeMediaCopy.detail(for: attachment))
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
    let vote: ([String]) -> Void
    @State private var selection: Set<String>

    init(poll: MatrixNativePollDescriptor, vote: @escaping ([String]) -> Void) {
        self.poll = poll
        self.vote = vote
        _selection = State(initialValue: poll.selectedOptionIDs)
    }

    private var totalVotes: Int {
        poll.options.reduce(0) { $0 + $1.voteCount }
    }

    private var showsResults: Bool {
        MatrixNativePollVisibilityContract.showsResults(
            isDisclosed: poll.isDisclosed,
            hasEnded: poll.hasEnded,
            hasVoted: !poll.selectedOptionIDs.isEmpty
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
                    selection = MatrixNativePollSelectionContract.toggled(
                        selection,
                        optionID: option.id,
                        maximum: poll.maxSelections
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: selection.contains(option.id)
                                ? (poll.maxSelections > 1 ? "checkmark.square.fill" : "largecircle.fill.circle")
                                : (poll.maxSelections > 1 ? "square" : "circle"))
                                .foregroundStyle(selection.contains(option.id) ? C.watch : C.textMuted)
                            Text(option.text)
                                .lineLimit(nil)
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
                .accessibilityLabel(option.text)
                .accessibilityValue(selection.contains(option.id) ? "Selected" : "Not selected")
                .accessibilityHint(poll.hasEnded ? "Poll ended" : "Double tap to change selection")
            }
            Text(
                showsResults
                    ? (poll.hasEnded ? "Poll ended · \(totalVotes) votes" : "\(totalVotes) votes")
                    : "Results hidden until the poll ends"
            )
                .font(.caption2)
                .foregroundStyle(C.textMuted)
            if !poll.hasEnded {
                Button(poll.selectedOptionIDs.isEmpty ? "Submit vote" : "Change vote") {
                    guard !selection.isEmpty else { return }
                    vote(Array(selection).sorted())
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(selection.isEmpty || selection.count > Int(poll.maxSelections))
                .accessibilityHint("Submits (selection.count) selected poll answers")
            }
        }
        .padding(11)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        .accessibilityElement(children: .contain)
        .onChange(of: poll.selectedOptionIDs) { _, selected in
            selection = selected
        }
    }
}

@MainActor
private final class MatrixNativeLinkPreviewStore {
    static let shared = MatrixNativeLinkPreviewStore()
    private var cache = MatrixNativeLinkPreviewCache()
    private var activeAccountScope: String?

    func value(accountScope: String, url: String) -> MatrixNativeLinkPreviewMetadata? {
        activate(accountScope)
        return cache.value(accountScope: accountScope, url: url)
    }

    func insert(_ value: MatrixNativeLinkPreviewMetadata, accountScope: String, url: String) {
        activate(accountScope)
        cache.insert(value, accountScope: accountScope, url: url)
    }

    func remove(accountScope: String, url: String) {
        cache.remove(accountScope: accountScope, url: url)
    }

    private func activate(_ accountScope: String) {
        guard !accountScope.isEmpty else { return }
        if let previous = activeAccountScope, previous != accountScope {
            cache.clear(accountScope: previous)
        }
        activeAccountScope = accountScope
    }
}

struct MatrixNativeLinkPreviewCard: View {
    let roomID: String
    let roomIsEncrypted: Bool
    let messageBody: String
    let enabled: Bool

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var preview: MatrixNativeLinkPreviewMetadata?
    @State private var isUnavailable = false
    @State private var preferenceAllowsPreview = false

    private var accountScope: String {
        matrixSession.currentWestreemUserID ?? ""
    }

    private var link: String? {
        enabled
            && preferenceAllowsPreview
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
            } else if enabled, link != nil, isUnavailable {
                Label(
                    "Preview unavailable. Open the link from the message.",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Link preview unavailable")
            }
        }
        .task(id: "\(accountScope)::\(enabled)::\(roomID)::\(messageBody)") {
            preview = nil
            isUnavailable = false
            preferenceAllowsPreview = await matrixSession.linkPreviewsEnabled(
                roomID: roomID,
                encrypted: roomIsEncrypted
            )
            guard enabled, preferenceAllowsPreview, !accountScope.isEmpty,
                  let link = MatrixNativeLinkPreviewContract.firstPublicHTTPURL(
                      in: messageBody
                  ) else { return }
            await load(link, accountScope: accountScope)
        }
        .onChange(of: link) { oldValue, newValue in
            guard let oldValue, oldValue != newValue, !accountScope.isEmpty else {
                return
            }
            MatrixNativeLinkPreviewStore.shared.remove(
                accountScope: accountScope,
                url: oldValue
            )
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

    private func load(_ link: String, accountScope: String) async {
        if let cached = MatrixNativeLinkPreviewStore.shared.value(
            accountScope: accountScope,
            url: link
        ) {
            preview = cached
            return
        }
        do {
            let loaded = try await APIClient.shared.matrixLinkPreview(for: link)
            guard !Task.isCancelled else { return }
            MatrixNativeLinkPreviewStore.shared.insert(
                loaded,
                accountScope: accountScope,
                url: link
            )
            preview = loaded
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            isUnavailable = true
        }
    }
}

struct MatrixNativeMediaStrip: View {
    let roomID: String
    let media: [MatrixNativeMediaDescriptor]
    @State private var selectedMedia: MatrixNativeMediaDescriptor?

    private var containsInlineAudio: Bool {
        media.contains { $0.effectiveKind == .audio || $0.effectiveKind == .voice }
    }

    var body: some View {
        Group {
            if media.count == 1, let item = media.first {
                mediaView(for: item)
            } else if containsInlineAudio {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(media) { item in
                        mediaView(for: item)
                    }
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                    ],
                    spacing: 4
                ) {
                    ForEach(media) { item in
                        mediaView(for: item)
                    }
                }
            }
        }
        .sheet(item: $selectedMedia) { item in
            MatrixNativeMediaViewer(roomID: roomID, media: item)
        }
    }

    @ViewBuilder
    private func mediaView(for item: MatrixNativeMediaDescriptor) -> some View {
        switch item.effectiveKind {
        case .audio, .voice:
            MatrixNativeInlineAudioMessage(roomID: roomID, media: item)
        case .file:
            MatrixNativeFileAttachmentRow(media: item) {
                selectedMedia = item
            }
        case .image, .video, .sticker:
            MatrixNativeRemoteMediaThumbnail(roomID: roomID, media: item)
                .onTapGesture { selectedMedia = item }
        }
    }
}

private struct MatrixNativeFileAttachmentRow: View {
    let media: MatrixNativeMediaDescriptor
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("File")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Text(MatrixNativeMediaCopy.detail(for: media))
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File attachment")
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
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .frame(maxWidth: .infinity)
                .frame(height: media.effectiveKind == .sticker ? 150 : 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            } else if state == .loading {
                ProgressView().tint(C.watch)
                    .frame(height: 44)
            }
        }
        .accessibilityLabel(MatrixNativeMediaCopy.displayTitle(for: media))
        .task(id: media.id) {
            guard [.image, .sticker, .video].contains(media.effectiveKind) else { return }
            state = .loading
            do {
                let data = try await matrixSession.mediaData(roomID: roomID, media: media)
                switch media.effectiveKind {
                case .image, .sticker:
                    guard let decoded = UIImage(data: data) else {
                        throw MatrixNativeMediaError.invalidAttachment
                    }
                    image = decoded
                case .video:
                    image = try await MatrixNativeMediaCopy.videoThumbnail(
                        from: data,
                        filename: media.filename
                    )
                case .audio, .voice, .file:
                    break
                }
                state = .ready
            } catch {
                state = .unavailable
            }
        }
    }
}

private struct MatrixNativeInlineAudioMessage: View {
    let roomID: String
    let media: MatrixNativeMediaDescriptor

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var player: AVPlayer?
    @State private var localFileURL: URL?
    @State private var timeObserver: Any?
    @State private var isLoading = true
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var errorMessage: String?

    private var effectiveDuration: TimeInterval {
        max(duration, media.duration ?? 0, 1)
    }

    var body: some View {
        HStack(spacing: 11) {
            Button(action: togglePlayback) {
                Group {
                    if isLoading {
                        ProgressView().tint(C.watch)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline.bold())
                    }
                }
                .frame(width: 40, height: 40)
                .foregroundStyle(C.bg)
                .background(errorMessage == nil ? C.watch : Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading || errorMessage != nil)
            .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(MatrixNativeMediaCopy.duration(isPlaying ? currentTime : effectiveDuration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(C.textMuted)
                    Spacer(minLength: 0)
                }

                Slider(
                    value: Binding(
                        get: { min(currentTime, effectiveDuration) },
                        set: { seek(to: $0) }
                    ),
                    in: 0...effectiveDuration
                )
                .tint(C.watch)
                .disabled(player == nil)
                .accessibilityLabel("Voice message progress")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: media.effectiveKind == .voice ? 310 : 360, alignment: .leading)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.borderSubtle))
        .task(id: media.id) { await load() }
        .onDisappear { cleanup() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        cleanup()
        do {
            let data = try await matrixSession.mediaData(roomID: roomID, media: media)
            let safeName = MatrixNativeMediaCopy.safeFilename(media.filename)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("matrix-audio-\(UUID().uuidString)-\(safeName)")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let player = AVPlayer(url: url)
            self.player = player
            localFileURL = url
            duration = media.duration ?? 0
            if duration <= 0 {
                duration = try await AVURLAsset(url: url).load(.duration).seconds
            }
            installTimeObserver(on: player)
            errorMessage = nil
        } catch {
            errorMessage = MatrixNativeMediaCopy.message(for: error)
        }
        isLoading = false
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= effectiveDuration - 0.1 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: TimeInterval) {
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func installTimeObserver(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
            if currentTime >= effectiveDuration - 0.05 {
                isPlaying = false
            }
        }
    }

    private func cleanup() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        isPlaying = false
        currentTime = 0
        if let localFileURL { try? FileManager.default.removeItem(at: localFileURL) }
        localFileURL = nil
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
                } else if let player, media.effectiveKind == .audio || media.effectiveKind == .voice {
                    // Pass MSC3245 waveform: convert [UInt16] (0–1024) → [Float] (0–1) for display.
                    let waveformFloats: [Float]? = media.waveform.map { $0.map { Float($0) / 1024.0 } }
                    MatrixNativeAudioPlayback(
                        player: player,
                        title: MatrixNativeMediaCopy.displayTitle(for: media),
                        waveform: waveformFloats
                    )
                } else if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                } else if let localFileURL {
                    VStack(spacing: 18) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(C.watch)
                        Text("File").foregroundStyle(C.text)
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
            .navigationTitle(MatrixNativeMediaCopy.displayTitle(for: media))
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
            if media.effectiveKind == .image || media.effectiveKind == .sticker {
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
                if [.audio, .voice, .video].contains(media.effectiveKind) {
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

/// Full-screen audio playback with waveform visualisation (MSC3245).
/// `waveform`: normalised 0–1 amplitude values received from the Matrix event.
/// When nil or empty, WaveformBarsView renders a static placeholder pattern.
private struct MatrixNativeAudioPlayback: View {
    let player: AVPlayer
    let title: String
    /// Optional MSC3245 waveform data (0–1 normalised). Nil for non-voice messages
    /// or when the sender did not capture waveform data.
    var waveform: [Float]? = nil

    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    private let staticBars: [Float] = (0..<40).map { i in
        // Generate a visually interesting static pattern when no waveform available.
        let t = Float(i) / 39
        return 0.2 + 0.6 * abs(sin(t * .pi * 4))
    }

    var body: some View {
        VStack(spacing: 20) {
            // Waveform visualisation — real data or static placeholder.
            let bars = waveform?.map { $0 } ?? staticBars
            WaveformBarsView(samples: bars, progress: progress)
                .frame(height: 60)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(C.text)
                .lineLimit(2)

            // Duration readout.
            HStack {
                Text(formatTime(currentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(C.textTertiary)

            // Scrubber.
            Slider(value: Binding(
                get: { progress },
                set: { newVal in
                    progress = newVal
                    let target = newVal * duration
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                }
            ))
            .tint(C.watch)

            // Play / pause.
            Button {
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play",
                      systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
        }
        .onAppear {
            // Observe playback time every 0.1 s for progress updates.
            player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { time in
                currentTime = time.seconds
                let dur = player.currentItem?.duration.seconds ?? 0
                if dur > 0, dur.isFinite {
                    duration = dur
                    progress = currentTime / dur
                }
                if player.timeControlStatus == .paused { isPlaying = false }
            }
        }
        .onDisappear { player.pause() }
        .accessibilityElement(children: .contain)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

private struct MatrixNativePollComposerSheet: View {
    let publish: (String, [String], UInt64, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var maxSelections: UInt64 = 1
    @State private var isDisclosed = true
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
                Section("Poll settings") {
                    Picker("Result visibility", selection: $isDisclosed) {
                        Text("Visible after voting").tag(true)
                        Text("Hidden until poll ends").tag(false)
                    }
                    Stepper(
                        "Selections per voter: \(maxSelections)",
                        value: $maxSelections,
                        in: 1...UInt64(max(1, options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count))
                    )
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
                            publish(
                                validated.0,
                                validated.1,
                                min(maxSelections, UInt64(validated.1.count)),
                                isDisclosed
                            )
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
    /// Live waveform amplitude samples (0–1 normalised), updated every 100 ms.
    @Published private(set) var waveformSamples: [Float] = []
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
            waveformSamples = []
            state = .recording
            // Sample amplitude every 100 ms and build MSC3245 waveform (0–1 normalised).
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    if self.elapsed >= MatrixNativeMediaPolicy.maximumVoiceDuration { self.finish() }
                    // AVAudioRecorder reports power in dB in the range [-160, 0].
                    // Convert to linear 0–1 amplitude.
                    let db = recorder.averagePower(forChannel: 0)
                    let linear = max(0, min(1, (db + 80) / 80))
                    // Cap at 120 samples; downsample by merging pairs when full.
                    if self.waveformSamples.count < 120 {
                        self.waveformSamples.append(linear)
                    } else {
                        var merged: [Float] = []
                        for i in stride(from: 0, to: self.waveformSamples.count - 1, by: 2) {
                            merged.append((self.waveformSamples[i] + self.waveformSamples[i + 1]) / 2)
                        }
                        merged.append(linear)
                        self.waveformSamples = merged
                    }
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
        waveformSamples = []
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func makeUpload() throws -> MatrixNativeUpload {
        guard state == .ready, let fileURL else {
            throw MatrixNativeMediaError.invalidAttachment
        }
        // Convert 0–1 linear samples to 0–1024 integers per MSC3245 spec.
        let waveform: [Int]? = waveformSamples.isEmpty
            ? nil
            : waveformSamples.map { Int(round($0 * 1024)) }
        return MatrixNativeUpload(
            kind: .voice,
            data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            filename: "voice-message.m4a",
            mimeType: "audio/mp4",
            duration: elapsed,
            waveform: waveform
        )
    }
}

/// Waveform bar chart for voice messages (MSC3245).
/// `samples`: normalised 0–1 amplitude values. Falls back to a static row of
/// equal-height bars when empty (e.g. before recording starts).
private struct WaveformBarsView: View {
    let samples: [Float]
    var progress: Double = 0 // 0–1, fraction played/recorded

    var body: some View {
        GeometryReader { geo in
            let count = max(1, samples.count)
            let barWidth = max(2, (geo.size.width - CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0 ..< count, id: \.self) { i in
                    let pct = count > 1 ? Double(i) / Double(count - 1) : 0
                    let amp = samples.isEmpty ? 0.4 : Double(samples[i])
                    let h = max(3, amp * geo.size.height)
                    Capsule()
                        .fill(pct <= progress ? C.watch : C.watch.opacity(0.3))
                        .frame(width: barWidth, height: h)
                }
            }
        }
        .frame(height: 40)
    }
}

private struct MatrixNativeVoiceRecorderSheet: View {
    let completion: (MatrixNativeUpload?) -> Void
    @StateObject private var recorder = MatrixNativeVoiceRecorder()

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(C.borderSubtle).frame(width: 42, height: 5)

            HStack(spacing: 10) {
                Circle()
                    .fill(recorder.state == .recording ? Color.red : C.watch)
                    .frame(width: 10, height: 10)
                    .opacity(recorder.state == .recording ? 1 : 0.55)
                Text(statusTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(C.text)
                Spacer(minLength: 0)
                Text(MatrixNativeMediaCopy.duration(recorder.elapsed))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(C.text)
            }

            Group {
                if recorder.state == .recording, !recorder.waveformSamples.isEmpty {
                    // Live MSC3245 amplitude samples while recording.
                    WaveformBarsView(samples: recorder.waveformSamples, progress: 1)
                        .padding(.horizontal, 8)
                } else {
                    HStack(spacing: 4) {
                        ForEach(0..<28, id: \.self) { index in
                            Capsule()
                                .fill(recorder.state == .recording ? C.watch : C.borderSubtle)
                                .frame(
                                    width: 4,
                                    height: waveformHeight(index: index)
                                )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 12)
            .background(C.elevated, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(C.borderSubtle))
            .symbolEffect(.pulse, isActive: recorder.state == .recording)

            HStack(spacing: 16) {
                Button(role: .destructive) {
                    recorder.discard()
                    completion(nil)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Discard voice message")

                if recorder.state == .recording {
                    Button {
                        recorder.finish()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.headline.bold())
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Stop recording")
                } else if recorder.state == .ready {
                    Button {
                        recorder.discard()
                        Task { await recorder.start() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Record again")

                    Button {
                        do {
                            completion(try recorder.makeUpload())
                        } catch {
                            completion(nil)
                        }
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .frame(minWidth: 96, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                } else {
                    Button {
                        Task { await recorder.start() }
                    } label: {
                        Label("Record", systemImage: "mic.fill")
                            .frame(minWidth: 118, minHeight: 44)
                    }
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
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
        .task {
            guard recorder.state == .idle else { return }
            await recorder.start()
        }
        .onDisappear {
            if recorder.state == .recording || recorder.state == .idle {
                recorder.discard()
            }
        }
    }

    private var statusTitle: String {
        switch recorder.state {
        case .idle, .requesting: "Preparing voice message"
        case .recording: "Recording voice message"
        case .ready: "Voice message ready"
        case .denied: "Microphone blocked"
        case .failed: "Recording too short"
        }
    }

    private func waveformHeight(index: Int) -> CGFloat {
        let phase = Double(index) * 0.7 + recorder.elapsed * 7
        let value = (sin(phase) + 1) / 2
        return CGFloat(14 + value * 38)
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
            return "\(displayTitle(for: upload)) · \(detail(for: upload))"
        }
        return "\(uploads.count) attachments"
    }

    static func displayTitle(for upload: MatrixNativeUpload) -> String {
        switch upload.kind {
        case .file:
            return upload.filename
        case .audio, .voice, .image, .video, .sticker:
            return label(for: upload.kind)
        }
    }

    static func displayTitle(for media: MatrixNativeMediaDescriptor) -> String {
        switch media.effectiveKind {
        case .file:
            return "File"
        case .audio, .voice, .image, .video, .sticker:
            return label(for: media.effectiveKind)
        }
    }

    static func detail(for upload: MatrixNativeUpload) -> String {
        if let duration = upload.duration,
           upload.kind == .audio || upload.kind == .voice || upload.kind == .video {
            return Self.duration(duration)
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(upload.data.count),
            countStyle: .file
        )
    }

    static func detail(for media: MatrixNativeMediaDescriptor) -> String {
        if let duration = media.duration,
           media.effectiveKind == .audio || media.effectiveKind == .voice || media.effectiveKind == .video {
            return Self.duration(duration)
        }
        if let size = media.size {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return label(for: media.effectiveKind)
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

    static func videoThumbnail(from data: Data, filename: String) async throws -> UIImage {
        let safeName = safeFilename(filename)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrix-video-thumb-\(UUID().uuidString)-\(safeName)")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let image = try await generator.image(
            at: CMTime(seconds: 0.25, preferredTimescale: 600)
        ).image
        return UIImage(cgImage: image)
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
