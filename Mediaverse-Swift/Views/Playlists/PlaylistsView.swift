import SwiftUI

// MARK: - Playlist Edit Sheet
// Presented as a sheet from both PlaylistsView and PlaylistDetailView.
// Fields: title, description, visibility. Includes inline delete with confirm.

struct PlaylistEditSheet: View {

    let playlistId: String
    let initialTitle: String
    let initialDescription: String?
    let initialVisibility: String
    let onSaved: (String, String?, String) -> Void   // title, description, visibility
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title:          String
    @State private var description:    String
    @State private var visibility:     String
    @State private var saving          = false
    @State private var showDeleteConfirm = false

    init(
        playlistId: String,
        initialTitle: String,
        initialDescription: String?,
        initialVisibility: String,
        onSaved: @escaping (String, String?, String) -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.playlistId         = playlistId
        self.initialTitle       = initialTitle
        self.initialDescription = initialDescription
        self.initialVisibility  = initialVisibility
        self.onSaved            = onSaved
        self.onDeleted          = onDeleted
        _title       = State(initialValue: initialTitle)
        _description = State(initialValue: initialDescription ?? "")
        _visibility  = State(initialValue: initialVisibility)
    }

    private let visOptions: [(String, String, String, String)] = [
        ("public",   "globe",     "Public",   "Anyone can see"),
        ("unlisted", "link",      "Unlisted", "Only with a link"),
        ("private",  "lock.fill", "Private",  "Only you can see"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // ── Title ─────────────────────────────────────────────────
                    fieldGroup(label: "Title *") {
                        TextField("Playlist title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .foregroundStyle(C.text)
                            .padding(12)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                            .submitLabel(.done)
                            .onSubmit { Task { await save() } }
                    }

                    // ── Description ───────────────────────────────────────────
                    fieldGroup(label: "Description") {
                        ZStack(alignment: .topLeading) {
                            if description.isEmpty {
                                Text("What is this playlist about?")
                                    .font(.body)
                                    .foregroundStyle(C.textMuted)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 14)
                            }
                            TextEditor(text: $description)
                                .frame(height: 88)
                                .font(.body)
                                .foregroundStyle(C.text)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                    }

                    // ── Visibility picker ──────────────────────────────────────
                    fieldGroup(label: "Visibility") {
                        HStack(spacing: 8) {
                            ForEach(visOptions, id: \.0) { val, icon, label, desc in
                                Button {
                                    visibility = val
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Image(systemName: icon)
                                                .font(.system(size: 11))
                                            Text(label)
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        Text(desc)
                                            .font(.system(size: 9))
                                            .opacity(0.7)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .background(visibility == val ? C.watch.opacity(0.15) : Color.white.opacity(0.05))
                                    .foregroundStyle(visibility == val ? C.watch : C.textMuted)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(visibility == val ? C.watch.opacity(0.5) : C.border, lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // ── Delete zone ───────────────────────────────────────────
                    if showDeleteConfirm {
                        VStack(spacing: 12) {
                            Text("Are you sure? This cannot be undone.")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.red)

                            HStack(spacing: 12) {
                                Button { showDeleteConfirm = false } label: {
                                    Text("Cancel")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.white.opacity(0.1))
                                        .foregroundStyle(C.text)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }

                                Button {
                                    Task { await deletePlaylist() }
                                } label: {
                                    Text("Yes, delete")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.red)
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.25), lineWidth: 1) }
                    } else {
                        Button { showDeleteConfirm = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                Text("Delete playlist")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.25), lineWidth: 1) }
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.vertical, 20)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(C.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(C.watch)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            content()
        }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        saving = true
        guard (try? await APIClient.shared.updatePlaylist(
            id: playlistId,
            title: trimmed,
            description: description.isEmpty ? nil : description,
            visibility: visibility
        )) != nil else { saving = false; return }
        onSaved(trimmed, description.isEmpty ? nil : description, visibility)
        saving = false
        dismiss()
    }

    private func deletePlaylist() async {
        try? await APIClient.shared.deletePlaylist(id: playlistId)
        onDeleted()
        dismiss()
    }
}

// MARK: - PlaylistsView

/// My Playlists screen — mirrors /playlists on web.
///
/// Layout:
///   - Loading  → 4 skeleton cards in 2-col grid
///   - Empty    → playlist icon + "No playlists yet"
///   - Loaded   → 2-col grid of playlist cards
///
/// Each card has a mosaic thumbnail (up to 4 quadrants), title, visibility,
/// and a ⋯ menu for Edit / Play all / Delete.
struct PlaylistsView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var playlists:       [Playlist] = []
    @State private var loading          = true
    @State private var editingPlaylist: Playlist?  = nil

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if loading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in skeletonCard }
                    }
                    .padding(C.pagePad)
                }
            } else if playlists.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(playlists) { pl in
                            playlistCard(pl)
                        }
                    }
                    .padding(C.pagePad)
                }
            }
        }
        .navigationTitle("My Playlists")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editingPlaylist) { pl in
            PlaylistEditSheet(
                playlistId:         pl.id,
                initialTitle:       pl.title,
                initialDescription: pl.description,
                initialVisibility:  pl.visibility,
                onSaved: { newTitle, newDesc, newVis in
                    playlists = playlists.map { p in
                        guard p.id == pl.id else { return p }
                        return Playlist(
                            id: p.id, title: newTitle, description: newDesc,
                            visibility: newVis, type: p.type, createdAt: p.createdAt,
                            itemCount: p.itemCount, thumbItems: p.thumbItems
                        )
                    }
                },
                onDeleted: {
                    playlists.removeAll { $0.id == pl.id }
                }
            )
        }
        .task { await load() }
    }

    // MARK: - Playlist card

    private func playlistCard(_ pl: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Thumbnail area → navigate to detail
            NavigationLink(value: AppRoute.playlist(pl.id)) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnailMosaic(thumbURLs: pl.thumbItems.compactMap { $0.video?.thumbnailUrl })
                        .aspectRatio(16/9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Dark gradient at bottom
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Item count badge
                    Text("\(pl.itemCount) video\(pl.itemCount != 1 ? "s" : "")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .buttonStyle(.plain)

            // ── Info row
            HStack(alignment: .top, spacing: 6) {

                // Title + visibility → navigate to detail
                NavigationLink(value: AppRoute.playlist(pl.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pl.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Image(systemName: visibilityIcon(pl.visibility))
                                .font(.system(size: 9))
                            Text(visibilityLabel(pl.visibility))
                                .font(.caption2)
                        }
                        .foregroundStyle(C.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                // ⋯ menu — NOT inside NavigationLink
                Menu {
                    Button {
                        editingPlaylist = pl
                    } label: {
                        Label("Edit playlist", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        editingPlaylist = pl
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(C.textMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
    }

    // MARK: - Thumbnail mosaic (mirrors PlaylistThumb in web)

    @ViewBuilder
    private func thumbnailMosaic(thumbURLs: [String]) -> some View {
        let urls = Array(thumbURLs.prefix(4))

        if urls.count >= 4 {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                spacing: 0
            ) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    AsyncImage(url: C.mediaURL(url)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Rectangle().fill(Color.white.opacity(0.08))
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipped()
                }
            }
        } else if let first = urls.first {
            AsyncImage(url: C.mediaURL(first)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Rectangle().fill(Color.white.opacity(0.08))
                }
            }
            .clipped()
        } else {
            ZStack {
                Color.white.opacity(0.05)
                Image(systemName: "play.rectangle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
    }

    // MARK: - Skeleton card

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)).frame(height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)).frame(width: 60, height: 10)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 52))
                .foregroundStyle(C.textMuted)

            Text("No playlists yet")
                .font(.title3.bold())
                .foregroundStyle(C.text)

            Text("Create a playlist from any video on the website.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        playlists = (try? await APIClient.shared.fetchPlaylists()) ?? []
        loading = false
    }

    // MARK: - Helpers

    private func visibilityIcon(_ vis: String) -> String {
        switch vis {
        case "unlisted": return "link"
        case "private":  return "lock.fill"
        default:         return "globe"
        }
    }

    private func visibilityLabel(_ vis: String) -> String {
        switch vis {
        case "unlisted": return "Unlisted"
        case "private":  return "Private"
        default:         return "Public"
        }
    }
}
