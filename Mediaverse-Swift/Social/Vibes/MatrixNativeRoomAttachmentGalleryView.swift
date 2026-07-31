import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

enum MatrixNativeRoomAttachmentGalleryTab: String, CaseIterable, Identifiable {
    case media = "Media"
    case documents = "Docs"
    case links = "Links"

    var id: String { rawValue }
}

private enum MatrixNativeRoomAttachmentGalleryLayout: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case list = "List"
    case timeline = "Timeline"
    var id: String { rawValue }
}

struct MatrixNativeRoomAttachmentGalleryView: View {
    let roomID: String
    let waveName: String
    let accountID: String
    let roomIsEncrypted: Bool
    let sections: (MatrixNativeRoomAttachmentGalleryTab) -> [MatrixNativeRoomAttachmentSection]
    @Binding var selection: Set<String>
    @Binding var activePreviewIndex: Int?
    let starredIDs: Set<String>
    let hasMore: Bool
    let loadMore: () -> Void
    let deleteForMe: ([String]) -> Void
    let deleteForEveryone: ([MatrixNativeEventReference]) -> Void
    let forward: ([String]) -> Void
    let setStarred: ([MatrixNativeRoomAttachment], Bool) -> Void

    @State private var tab = MatrixNativeRoomAttachmentGalleryTab.media
    @State private var layout = MatrixNativeRoomAttachmentGalleryLayout.grid
    @State private var deleteConfirmationPresented = false

    private var allItems: [MatrixNativeRoomAttachment] {
        MatrixNativeRoomAttachmentGalleryTab.allCases.flatMap { category in
            sections(category).flatMap(\.items)
        }
    }

    private var selectedItems: [MatrixNativeRoomAttachment] {
        allItems.filter { selection.contains($0.id) }
    }

    private var mediaItems: [MatrixNativeRoomAttachment] {
        sections(.media).flatMap(\.items).filter {
            if case .media = $0.payload { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(waveName)'s Gallery").font(.headline).lineLimit(1)
                Spacer()
                if tab == .media {
                    Picker("Gallery layout", selection: $layout) {
                        ForEach(MatrixNativeRoomAttachmentGalleryLayout.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                }
            }.padding(.horizontal, 16).padding(.top, 8)
            Picker("Room attachments", selection: $tab) {
                ForEach(MatrixNativeRoomAttachmentGalleryTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch tab {
                case .media:
                    MatrixNativeRoomAttachmentMediaGrid(
                        roomID: roomID,
                        sections: sections(.media),
                        layout: layout,
                        selection: $selection,
                        hasMore: hasMore,
                        loadMore: loadMore,
                        open: openMedia
                    )
                case .documents:
                    MatrixNativeRoomAttachmentDocumentList(
                        roomID: roomID,
                        sections: sections(.documents),
                        selection: $selection,
                        hasMore: hasMore,
                        loadMore: loadMore
                    )
                case .links:
                    MatrixNativeRoomAttachmentLinkList(
                        roomID: roomID,
                        roomIsEncrypted: roomIsEncrypted,
                        sections: sections(.links),
                        selection: $selection,
                        hasMore: hasMore,
                        loadMore: loadMore
                    )
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty {
                MatrixNativeRoomAttachmentSelectionFooter(
                    count: selection.count,
                    canDelete: !selectedItems.isEmpty,
                    allStarred: !selectedItems.isEmpty
                        && selectedItems.allSatisfy { starredIDs.contains($0.id) },
                    delete: { deleteConfirmationPresented = true },
                    forward: { forward(selectedItems.map(\.id)) },
                    star: {
                        setStarred(
                            selectedItems,
                            !selectedItems.allSatisfy { starredIDs.contains($0.id) }
                        )
                    },
                    clear: { selection.removeAll() }
                )
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { activePreviewIndex != nil },
            set: { if !$0 { activePreviewIndex = nil } }
        )) {
            if let activePreviewIndex {
                MatrixNativeRoomAttachmentPagedViewer(
                    roomID: roomID,
                    items: mediaItems,
                    selectedIndex: Binding(
                        get: { activePreviewIndex },
                        set: { self.activePreviewIndex = $0 }
                    ),
                    dismiss: { self.activePreviewIndex = nil }
                )
            }
        }
        .confirmationDialog(
            "Delete selected attachments?",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete for Me", role: .destructive) {
                deleteForMe(selectedItems.map(\.id))
                selection.removeAll()
            }
            if !selectedItems.isEmpty, selectedItems.allSatisfy(\.canDeleteForEveryone) {
                Button("Delete for Everyone", role: .destructive) {
                    deleteForEveryone(selectedItems.map(\.eventReference))
                    selection.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete for Everyone is available only when Matrix room permissions allow redaction.")
        }
    }

    private func openMedia(_ attachment: MatrixNativeRoomAttachment) {
        guard selection.isEmpty else {
            toggleSelection(attachment.id)
            return
        }
        activePreviewIndex = mediaItems.firstIndex { $0.id == attachment.id }
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct MatrixNativeRoomAttachmentMediaGrid: View {
    let roomID: String
    let sections: [MatrixNativeRoomAttachmentSection]
    let layout: MatrixNativeRoomAttachmentGalleryLayout
    @Binding var selection: Set<String>
    let hasMore: Bool
    let loadMore: () -> Void
    let open: (MatrixNativeRoomAttachment) -> Void

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 2), count: layout == .grid ? 3 : 1) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(section.items) { item in
                                if case let .media(media) = item.payload {
                                    MatrixNativeRoomAttachmentMediaCell(
                                        roomID: roomID,
                                        attachment: item,
                                        media: media,
                                        showMetadata: layout != .grid,
                                        selected: selection.contains(item.id)
                                    )
                                    .onTapGesture { open(item) }
                                    .onLongPressGesture(minimumDuration: 0.35) {
                                        toggle(item.id)
                                    }
                                    .onAppear {
                                        if hasMore,
                                           item.id == sections.last?.items.last?.id {
                                            loadMore()
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        MatrixNativeRoomAttachmentSectionHeader(title: section.title)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct MatrixNativeRoomAttachmentMediaCell: View {
    let roomID: String
    let attachment: MatrixNativeRoomAttachment
    let media: MatrixNativeRoomMediaAttachment
    let showMetadata: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            if media.mediaKind == .audio || media.mediaKind == .voice {
                LinearGradient(colors: [Color.accentColor.opacity(0.35), .purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.white)
            } else {
                MatrixNativeRoomAttachmentThumbnail(roomID: roomID, descriptor: media.descriptor)
                    .aspectRatio(showMetadata ? 16 / 9 : 1, contentMode: .fill).clipped()
            }

            if media.mediaKind == .video {
                Image(systemName: "play.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(.black.opacity(0.5), in: Circle())
                if let duration = media.duration {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(MatrixNativeRoomAttachmentFormatting.duration(duration))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.62), in: Capsule())
                                .padding(5)
                        }
                    }
                }
            }

            if selected {
                Color.accentColor.opacity(0.22)
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(6)
                    }
                    Spacer()
                }
            }
            if showMetadata {
                VStack { Spacer(); HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title).lineLimit(1).font(.caption.weight(.semibold))
                        Text("Sent by \(attachment.senderID) · \(attachment.timestamp.formatted(date: .abbreviated, time: .shortened))").lineLimit(1).font(.caption2)
                    }; Spacer()
                }.foregroundStyle(.white).padding(8).background(.black.opacity(0.62)) }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(media.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct MatrixNativeRoomAttachmentDocumentList: View {
    let roomID: String
    let sections: [MatrixNativeRoomAttachmentSection]
    @Binding var selection: Set<String>
    let hasMore: Bool
    let loadMore: () -> Void
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var previewFile: MatrixNativeSecurePreviewFile?

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        if case let .document(document) = item.payload {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 42, height: 42)
                                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.title).font(.body.weight(.medium)).lineLimit(2)
                                    Text(MatrixNativeRoomAttachmentFormatting.documentDetail(document))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "chevron.right")
                                    .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selection.isEmpty { Task { await open(document) } }
                                else { toggle(item.id) }
                            }
                            .onLongPressGesture(minimumDuration: 0.35) { toggle(item.id) }
                            .onAppear {
                                if hasMore, item.id == sections.last?.items.last?.id { loadMore() }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .sheet(item: $previewFile, onDismiss: cleanupPreview) { file in
            MatrixNativeQuickLookPreview(url: file.url).ignoresSafeArea()
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    @MainActor
    private func open(_ document: MatrixNativeRoomDocumentAttachment) async {
        guard let data = try? await matrixSession.mediaData(roomID: roomID, media: document.descriptor) else { return }
        let ext = String(document.fileExtension.filter { $0.isLetter || $0.isNumber }.prefix(12))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrix-document-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            previewFile = MatrixNativeSecurePreviewFile(url: url)
        } catch { try? FileManager.default.removeItem(at: url) }
    }

    private func cleanupPreview() {
        if let url = previewFile?.url { try? FileManager.default.removeItem(at: url) }
        previewFile = nil
    }
}

private struct MatrixNativeRoomAttachmentLinkList: View {
    let roomID: String
    let roomIsEncrypted: Bool
    let sections: [MatrixNativeRoomAttachmentSection]
    @Binding var selection: Set<String>
    let hasMore: Bool
    let loadMore: () -> Void

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        if case let .link(link) = item.payload {
                            VStack(alignment: .leading, spacing: 8) {
                              HStack(alignment: .top, spacing: 12) {
                                if let preview = link.previewDescriptor {
                                    MatrixNativeRoomAttachmentThumbnail(
                                        roomID: roomID,
                                        descriptor: preview
                                    )
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                } else {
                                    Image(systemName: "link")
                                        .frame(width: 44, height: 44)
                                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(link.title).font(.body.weight(.medium)).lineLimit(2)
                                    if let summary = link.summary, !summary.isEmpty {
                                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Text(link.domain).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if selection.contains(item.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                              }
                              MatrixNativeLinkPreviewCard(
                                  roomID: roomID,
                                  roomIsEncrypted: roomIsEncrypted,
                                  messageBody: link.url.absoluteString,
                                  enabled: true
                              )
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selection.isEmpty {
                                    UIApplication.shared.open(link.url)
                                } else {
                                    toggle(item.id)
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.35) { toggle(item.id) }
                            .onAppear {
                                if hasMore, item.id == sections.last?.items.last?.id { loadMore() }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct MatrixNativeSecurePreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MatrixNativeQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct MatrixNativeRoomAttachmentSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(.bar)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MatrixNativeRoomAttachmentSelectionFooter: View {
    let count: Int
    let canDelete: Bool
    let allStarred: Bool
    let delete: () -> Void
    let forward: () -> Void
    let star: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack {
            Button(action: clear) {
                Label("Clear", systemImage: "xmark.circle")
            }
            Spacer()
            Text("\(count) selected").font(.subheadline.weight(.semibold))
            Spacer()
            Button(action: star) {
                Image(systemName: allStarred ? "star.slash" : "star")
            }
            .accessibilityLabel(allStarred ? "Unstar" : "Star")
            Button(action: forward) { Image(systemName: "arrowshape.turn.up.right") }
                .accessibilityLabel("Forward")
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .accessibilityLabel("Delete")
                .disabled(!canDelete)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MatrixNativeRoomAttachmentPagedViewer: View {
    let roomID: String
    let items: [MatrixNativeRoomAttachment]
    @Binding var selectedIndex: Int
    let dismiss: () -> Void

    @State private var verticalOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(max(0.25, 1 - Double(abs(verticalOffset) / 500)))
                .ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if case let .media(media) = item.payload {
                        MatrixNativeRoomAttachmentViewerPage(
                            roomID: roomID,
                            media: media
                        )
                        .tag(index)
                    }
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
            .offset(y: verticalOffset)
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            verticalOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.height) > 150
                            || abs(value.predictedEndTranslation.height) > 220 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                verticalOffset = 0
                            }
                        }
                    }
            )

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close attachment viewer")
        }
        .statusBarHidden()
    }
}

private struct MatrixNativeRoomAttachmentViewerPage: View {
    let roomID: String
    let media: MatrixNativeRoomMediaAttachment

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var image: UIImage?
    @State private var poster: UIImage?
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = min(max(lastScale * $0, 1), 5) }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                        }
                    }
            } else if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let poster {
                ZStack {
                    Image(uiImage: poster).resizable().scaledToFit()
                    Image(systemName: media.mediaKind == .video ? "play.fill" : "waveform")
                        .font(.title2.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(.black.opacity(0.55), in: Circle())
                }
            } else if failed {
                ContentUnavailableView(
                    "Attachment unavailable",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            } else {
                ProgressView("Loading securely…").tint(.white).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: media.descriptor.id) { await load() }
        .onDisappear {
            player?.pause()
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }

    @MainActor
    private func load() async {
        do {
            if media.mediaKind == .video,
               let thumbnail = try? await matrixSession.mediaThumbnailData(roomID: roomID, media: media.descriptor) {
                poster = UIImage(data: thumbnail)
            }
            let data = try await matrixSession.mediaData(
                roomID: roomID,
                media: media.descriptor
            )
            if media.mediaKind == .video || media.mediaKind == .audio || media.mediaKind == .voice {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("matrix-room-gallery-\(UUID().uuidString)")
                    .appendingPathExtension("mp4")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                temporaryURL = url
                player = AVPlayer(url: url)
            } else if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

private struct MatrixNativeRoomAttachmentThumbnail: View {
    let roomID: String
    let descriptor: MatrixNativeMediaDescriptor

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: descriptor.id) {
            if let data = try? await matrixSession.mediaThumbnailData(roomID: roomID, media: descriptor),
               let decoded = UIImage(data: data) { image = decoded; return }
            if let data = try? await matrixSession.mediaData(roomID: roomID, media: descriptor) {
                image = UIImage(data: data)
            }
        }
    }
}

private enum MatrixNativeRoomAttachmentFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func documentDetail(_ document: MatrixNativeRoomDocumentAttachment) -> String {
        [
            document.fileExtension.uppercased(),
            document.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
}
