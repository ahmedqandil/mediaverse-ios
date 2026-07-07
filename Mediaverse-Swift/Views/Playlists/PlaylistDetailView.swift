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
    @State private var isReordering  = false
    @State private var isSavingOrder = false
    @State private var orderError:   String?

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
                if items.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isReordering ? (isSavingOrder ? "Saving..." : "Done") : "Reorder") {
                            if isReordering {
                                Task { await saveOrderAndExit() }
                            } else {
                                orderError = nil
                                shuffled = false
                                isReordering = true
                            }
                        }
                        .disabled(isSavingOrder)
                        .foregroundStyle(C.watch)
                    }
                }

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
            case .video(let id):   VideoWatchView(videoId: id, playlistId: playlistId)
            case .episode(let id): EpisodeWatchView(episodeId: id)
            case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
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

                if let orderError {
                    Text(orderError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, C.pagePad)
                        .padding(.top, 10)
                }

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
                                itemRow(item: item, video: video, position: idx + 1, isOwner: pl.isOwner, canMoveUp: idx > 0, canMoveDown: idx < items.count - 1)
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

    private func itemRow(item: PlaylistDetailItem, video: PlaylistDetailVideo, position: Int, isOwner: Bool, canMoveUp: Bool, canMoveDown: Bool) -> some View {
        HStack(spacing: 12) {

            // Position number
            Text("\(position)")
                .font(.caption.weight(.medium))
                .foregroundStyle(C.textMuted)
                .frame(width: 24, alignment: .center)

            // Thumbnail → watch
            playlistVideoLink(video: video) {
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
            playlistVideoLink(video: video) {
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

            if isOwner && isReordering {
                VStack(spacing: 4) {
                    Button {
                        moveItem(item.id, direction: -1)
                    } label: {
                        MediaverseIcon(name: "chevron-up", fallbackSystemName: "chevron.up")
                            .frame(width: 12, height: 12)
                            .foregroundStyle(canMoveUp ? C.text : C.textMuted.opacity(0.35))
                            .frame(width: 30, height: 26)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!canMoveUp)
                    .buttonStyle(.plain)

                    Button {
                        moveItem(item.id, direction: 1)
                    } label: {
                        MediaverseIcon(name: "chevron-down", fallbackSystemName: "chevron.down")
                            .frame(width: 12, height: 12)
                            .foregroundStyle(canMoveDown ? C.text : C.textMuted.opacity(0.35))
                            .frame(width: 30, height: 26)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(!canMoveDown)
                    .buttonStyle(.plain)
                }
            } else if isOwner {
                Button {
                    Task { await removeItem(id: item.id) }
                } label: {
                    MediaverseIcon(name: "xmark", fallbackSystemName: "xmark")
                        .frame(width: 11, height: 11)
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

    @ViewBuilder
    private func playlistVideoLink<Content: View>(video: PlaylistDetailVideo, @ViewBuilder content: () -> Content) -> some View {
        if video.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" {
            NavigationLink(value: AppRoute.media(id: video.id, type: video.type)) {
                content()
            }
        } else {
            NavigationLink {
                VideoWatchView(videoId: video.id, playlistId: playlistId)
            } label: {
                content()
            }
        }
    }

    // MARK: - Thumbnail mosaic (same logic as PlaylistsView)

    @ViewBuilder
    private func thumbnailMosaic(thumbURLs: [String]) -> some View {
        let urls = Array(thumbURLs.prefix(4))

        if urls.count >= 4 {
            GeometryReader { geo in
                let cellWidth = geo.size.width / 2
                let cellHeight = geo.size.height / 2

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mosaicImage(urls[0])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(urls[1])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: 0) {
                        mosaicImage(urls[2])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(urls[3])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
        } else if let first = urls.first {
            mosaicImage(first)
        } else {
            ZStack {
                Color.white.opacity(0.05)
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.white.opacity(0.2))
            }
        }
    }

    private func mosaicImage(_ url: String) -> some View {
        AsyncImage(url: C.mediaURL(url)) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .clipped()
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
        playDest = AppRoute.media(id: first.id, type: first.type)
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

    private func moveItem(_ id: String, direction: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = from + direction
        guard items.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            let item = items.remove(at: from)
            items.insert(item, at: to)
        }
        orderError = nil
    }

    private func saveOrderAndExit() async {
        guard !isSavingOrder else { return }
        isSavingOrder = true
        orderError = nil
        do {
            try await APIClient.shared.reorderPlaylist(playlistId: playlistId, order: items.map { $0.id })
            isReordering = false
        } catch {
            orderError = "Could not save playlist order. Please try again."
        }
        isSavingOrder = false
    }

    // MARK: - Load

    private func load() async {
        loading = true
        error   = false
        do {
            let detail  = try await APIClient.shared.fetchPlaylistDetail(id: playlistId)
            playlist    = detail
            items       = detail.items
            isReordering = false
            orderError = nil
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
