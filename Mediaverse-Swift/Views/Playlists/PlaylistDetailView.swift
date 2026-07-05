import SwiftUI

/// Playlist detail screen — mirrors /playlist/[id] on web.
///
/// Layout (vertical scroll):
///   - Cover mosaic (same logic as PlaylistsView thumbnail)
///   - Title, item count, total duration, visibility label
///   - Description (if present)
///   - "Play all" + "Shuffle" buttons
///   - Edit button (if isOwner, shown in toolbar)
///   - Scrollable item list — tap item → VideoWatchView, swipe-to-remove (owner)
struct PlaylistDetailView: View {

    let playlistId: String

    @EnvironmentObject private var auth: AuthManager

    @State private var playlist:     PlaylistDetail?
    @State private var items:        [PlaylistDetailItem] = []
    @State private var loading       = true
    @State private var error         = false
    @State private var shuffled      = false
    @State private var showEdit      = false
    @State private var playDest:     AppRoute? = nil
    @State private var wasDeleted    = false

    @Environment(\.dismiss) private var dismiss

    // Thumbnail width for item rows (web: w-32 = 128pt)
    private let thumbW: CGFloat = 128
    private var thumbH: CGFloat { (thumbW * 9 / 16).rounded() }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if loading {
                ProgressView()
                    .tint(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if error || playlist == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(C.textMuted)
                    Text("Playlist not found")
                        .font(.title3.bold())
                        .foregroundStyle(C.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pl = playlist {
                mainContent(pl)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(playlist?.title ?? "Playlist")
        .toolbar {
            if let pl = playlist, pl.isOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEdit = true }
                        .foregroundStyle(C.watch)
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            if let pl = playlist {
                PlaylistEditSheet(
                    playlistId:         pl.id,
                    initialTitle:       pl.title,
                    initialDescription: pl.description,
                    initialVisibility:  pl.visibility,
                    onSaved: { _, _, _ in
                        // Reload to pick up updated title / description / visibility
                        Task { await load() }
                    },
                    onDeleted: {
                        wasDeleted = true
                    }
                )
            }
        }
        .onChange(of: wasDeleted) { _, deleted in
            if deleted { dismiss() }
        }
        .navigationDestination(item: $playDest) { route in
            switch route {
            case .video(let id):   VideoWatchView(videoId: id)
            case .episode(let id): EpisodeWatchView(episodeId: id)
            default: EmptyView()
            }
        }
        .task { await load() }
    }

    // MARK: - Main content

    @ViewBuilder
    private func mainContent(_ pl: PlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Cover mosaic ──────────────────────────────────────────────
                let thumbURLs = items.compactMap { $0.video?.thumbnailUrl }
                thumbnailMosaic(thumbURLs: thumbURLs)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, C.pagePad)

                // ── Info block ────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text(pl.title)
                        .font(.title2.bold())
                        .foregroundStyle(C.text)

                    // Count · Duration · Visibility
                    let totalMins = Int(items.reduce(0.0) { $0 + ($1.video?.duration ?? 0) } / 60)
                    HStack(spacing: 6) {
                        Text("\(items.count) \(pl.type == "short" ? "short" : "video")\(items.count != 1 ? "s" : "")")
                        if totalMins > 0 {
                            Text("·")
                            Text("\(totalMins) min")
                        }
                        Text("·")
                        Image(systemName: visibilityIcon(pl.visibility))
                        Text(visibilityLabel(pl.visibility))
                    }
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)

                    if let desc = pl.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 16)

                // ── Action buttons ─────────────────────────────────────────────
                HStack(spacing: 10) {
                    Button {
                        playAll()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 13))
                            Text("Play all").font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(C.watch)
                        .clipShape(Capsule())
                    }
                    .disabled(items.isEmpty)

                    Button {
                        toggleShuffle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle").font(.system(size: 13))
                            Text("Shuffle").font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(shuffled ? C.bg : C.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(shuffled ? C.watch : Color.white.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .disabled(items.isEmpty)
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 16)

                // ── Divider ────────────────────────────────────────────────────
                Divider()
                    .background(C.border)
                    .padding(.vertical, 16)

                // ── Item list ─────────────────────────────────────────────────
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 36))
                            .foregroundStyle(C.textMuted)
                        Text("No \(pl.type == "short" ? "shorts" : "videos") yet.")
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            if let video = item.video {
                                itemRow(item: item, video: video, position: idx + 1, isOwner: pl.isOwner)
                                Divider()
                                    .background(C.border)
                                    .padding(.leading, C.pagePad + 24 + 12 + thumbW + 12)
                            }
                        }
                    }
                }

                // Bottom spacer
                Color.clear.frame(height: 40)
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Item row

    private func itemRow(item: PlaylistDetailItem, video: PlaylistDetailVideo, position: Int, isOwner: Bool) -> some View {
        HStack(spacing: 12) {

            // Position number
            Text("\(position)")
                .font(.caption.weight(.medium))
                .foregroundStyle(C.textMuted)
                .frame(width: 24, alignment: .center)

            // Thumbnail → watch
            NavigationLink(value: AppRoute.media(id: video.id, type: video.type)) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: C.mediaURL(video.thumbnailUrl)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Rectangle().fill(Color.white.opacity(0.08))
                        }
                    }
                    .frame(width: thumbW, height: thumbH)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    if let dur = video.duration {
                        durationBadge(dur)
                    }
                }
                .frame(width: thumbW, height: thumbH)
            }
            .buttonStyle(.plain)

            // Info → watch
            NavigationLink(value: AppRoute.media(id: video.id, type: video.type)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let v = video.views, v > 0 {
                        Text("\(fmtCount(v)) views")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Remove button (owner only)
            if isOwner {
                Button {
                    Task { await removeItem(id: item.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
    }

    // MARK: - Thumbnail mosaic (same logic as PlaylistsView)

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
                    .font(.system(size: 40))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
    }

    // MARK: - Duration badge

    @ViewBuilder
    private func durationBadge(_ secs: Double) -> some View {
        let h   = Int(secs) / 3600
        let m   = (Int(secs) % 3600) / 60
        let s   = Int(secs) % 60
        let lbl = h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"

        Text(lbl)
            .font(.system(size: 10, weight: .semibold))
            .fontDesign(.monospaced)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    // MARK: - Actions

    private func playAll() {
        let list = shuffled ? items.shuffled() : items
        guard let first = list.first?.video else { return }
        playDest = .video(first.id)
    }

    private func toggleShuffle() {
        if shuffled {
            // Restore original order from API
            if let pl = playlist { items = pl.items }
        } else {
            items = items.shuffled()
        }
        shuffled.toggle()
    }

    private func removeItem(id: String) async {
        // Optimistic update
        items.removeAll { $0.id == id }
        try? await APIClient.shared.removePlaylistItem(playlistId: playlistId, itemId: id)
        // Persist new order after removal
        let order = items.map { $0.id }
        try? await APIClient.shared.reorderPlaylist(playlistId: playlistId, order: order)
    }

    // MARK: - Load

    private func load() async {
        loading = true
        error   = false
        do {
            let detail  = try await APIClient.shared.fetchPlaylistDetail(id: playlistId)
            playlist    = detail
            items       = detail.items
        } catch {
            self.error  = true
        }
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

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
