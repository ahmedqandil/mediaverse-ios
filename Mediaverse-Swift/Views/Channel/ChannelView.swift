import SwiftUI

@MainActor
private enum ChannelPageRenderCache {
    private struct Snapshot {
        let channel: ChannelDetail
        let followStatus: FollowStatus?
        let shorts: [Short]?
        let playlists: [ChannelPlaylist]?
        let cachedAt: Date
    }

    private static let ttl: TimeInterval = 120
    private static let maxEntries = 24
    private static var snapshots: [String: Snapshot] = [:]

    static func snapshot(for handle: String) -> (ChannelDetail, FollowStatus?, [Short]?, [ChannelPlaylist]?)? {
        let key = cacheKey(for: handle)
        guard let snapshot = snapshots[key] else { return nil }
        guard Date().timeIntervalSince(snapshot.cachedAt) < ttl else {
            snapshots[key] = nil
            return nil
        }
        return (snapshot.channel, snapshot.followStatus, snapshot.shorts, snapshot.playlists)
    }

    static func store(
        channel: ChannelDetail,
        followStatus: FollowStatus?,
        shorts: [Short]?,
        playlists: [ChannelPlaylist]?,
        handle: String
    ) {
        snapshots[cacheKey(for: handle)] = Snapshot(
            channel: channel,
            followStatus: followStatus,
            shorts: shorts,
            playlists: playlists,
            cachedAt: Date()
        )
        pruneIfNeeded()
    }

    private static func pruneIfNeeded() {
        guard snapshots.count > maxEntries else { return }
        let overflow = snapshots.count - maxEntries
        let keysToRemove = snapshots
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(overflow)
            .map(\.key)
        keysToRemove.forEach { snapshots[$0] = nil }
    }

    private static func cacheKey(for handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - ChannelView

struct ChannelView: View {

    let handle: String

    @Environment(\.dismiss) private var dismiss

    @State private var channel:         ChannelDetail?
    @State private var followStatus:    FollowStatus?
    @State private var shorts:          [Short]? = nil
    @State private var playlists:       [ChannelPlaylist]?         = nil
    @State private var isLoading:       Bool  = true
    @State private var activeTab:       CTab  = .videos
    @State private var descExpanded:    Bool  = false
    @State private var followLoading:   Bool  = false
    @State private var notifyLoading:   Bool  = false
    @State private var loadError:       String?
    @State private var imagePrefetchTask: Task<Void, Never>?

    enum CTab: String, CaseIterable, Identifiable {
        case videos, shorts, playlists, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .videos:    return "Videos"
            case .shorts:    return "Shorts"
            case .playlists: return "Playlists"
            case .about:     return "About"
            }
        }
    }

    var isFollowing: Bool { followStatus?.subscribed ?? false }
    var notifyOn:    Bool { followStatus?.notifyOnPublish ?? true }
    var followerCount: Int { followStatus?.count ?? channel?.followerCount ?? 0 }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(C.watch)
            } else if let ch = channel {
                channelContent(ch)
            } else {
                loadFailureView
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .enablesInteractiveSwipeBack()
        .task { await load() }
        .onChange(of: activeTab) { _, _ in
            if let channel { prefetchChannelImages(channel) }
        }
        .onDisappear {
            imagePrefetchTask?.cancel()
            imagePrefetchTask = nil
        }
    }

    // MARK: - Main content

    private func channelContent(_ ch: ChannelDetail) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let topInset = geo.safeAreaInsets.top

            ZStack(alignment: .topLeading) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(ch, width: width)
                        tabBar(ch, width: width)
                        tabContent(ch)
                            .frame(width: max(0, width - C.pagePad * 2), alignment: .topLeading)
                            .padding(.top, 20)
                            .padding(.bottom, 32)
                    }
                    .frame(width: width, alignment: .top)
                }
                .frame(width: width)
                .clipped()
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    C.lightHaptic()
                    await load(showSpinner: false)
                }

                heroBackButton()
                    .padding(.leading, 16)
                    .padding(.top, max(12, topInset - 6))
            }
        }
    }

    private func heroBackButton() -> some View {
        Button {
            dismiss()
        } label: {
            MediaverseIcon(name: "chevron-left", fallbackSystemName: "chevron.left")
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.30))
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero

    private func heroSection(_ ch: ChannelDetail, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let url = C.mediaURL(ch.bannerUrl) {
                    CachedRemoteImage(url: url, targetSize: CGSize(width: width, height: 200)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        C.surface
                    }
                    .frame(width: width, height: 200)
                    .clipped()
                    .overlay {
                        ZStack {
                            LinearGradient(
                                colors: [.black.opacity(0.92), .black.opacity(0.60), .black.opacity(0.10)],
                                startPoint: .leading, endPoint: .trailing
                            )
                            LinearGradient(
                                colors: [.black, .black.opacity(0.70), .black.opacity(0.20), .clear],
                                startPoint: .bottom, endPoint: .init(x: 0.5, y: 0.35)
                            )
                        }
                    }
                } else {
                    LinearGradient(
                        colors: [C.surface, C.bg],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .frame(width: width, height: 200)
                }

                HStack(alignment: .bottom, spacing: 16) {
                    channelAvatar(ch)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(ch.name)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(C.text)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if ch.verified {
                                Circle()
                                    .fill(C.watch)
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        Text("✓").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                                    }
                            }
                        }

                        HStack(spacing: 10) {
                            Text("@\(ch.handle)")
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if followerCount > 0 {
                                Text("·")
                                    .foregroundStyle(C.textMuted.opacity(0.4))
                                Text(fmtCount(followerCount) + " followers")
                                    .font(.caption)
                                    .foregroundStyle(C.textMuted)
                                    .lineLimit(1)
                            }
                            if let ct = ch.channelType, ct != "general", !ct.isEmpty {
                                Text(ct.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(C.watch)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(C.watch.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: max(0, width - C.pagePad * 2), alignment: .leading)
                .padding(.horizontal, C.pagePad)
                .padding(.bottom, 12)
            }
            .frame(width: width, height: 200)

            VStack(alignment: .leading, spacing: 12) {
                if let desc = ch.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(descExpanded ? nil : 2)
                        if desc.count > 120 {
                            Button {
                                withAnimation { descExpanded.toggle() }
                            } label: {
                                Text(descExpanded ? "Show less" : "Read more")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(C.watch)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await toggleFollow(ch) }
                    } label: {
                        Text(isFollowing ? "✓ Following" : "Follow")
                            .font(.subheadline.bold())
                            .foregroundStyle(isFollowing ? .white : .black)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(isFollowing ? .white.opacity(0.15) : C.watch)
                            .clipShape(Capsule())
                            .overlay {
                                if isFollowing { Capsule().stroke(C.border, lineWidth: 1) }
                            }
                    }
                    .disabled(followLoading)

                    // Bell — only when following
                    if isFollowing {
                        Button {
                            Task { await toggleNotify(ch) }
                        } label: {
                            Image(systemName: notifyOn ? "bell.fill" : "bell.slash")
                                .font(.system(size: 14))
                                .foregroundStyle(notifyOn ? .white : C.textMuted)
                                .frame(width: 40, height: 40)
                                .background(notifyOn ? .white.opacity(0.20) : C.surface)
                                .clipShape(Circle())
                                .overlay { Circle().stroke(notifyOn ? .white.opacity(0.30) : C.border, lineWidth: 1) }
                        }
                        .disabled(notifyLoading)
                    }

                    Button {
                        guard let url = URL(string: "\(C.baseURL)/channel/\(ch.handle)") else { return }
                        UIActivityViewController(activityItems: [url], applicationActivities: nil).presentFromRoot()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(C.text)
                            .frame(width: 40, height: 40)
                            .background(C.surface)
                            .clipShape(Circle())
                            .overlay { Circle().stroke(C.border, lineWidth: 1) }
                    }
                }
            }
            .frame(width: max(0, width - C.pagePad * 2), alignment: .leading)
            .padding(.horizontal, C.pagePad)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background(C.bg)
        }
        .frame(width: width)
    }

    private func channelAvatar(_ ch: ChannelDetail) -> some View {
        Group {
            if let url = C.mediaURL(ch.avatarUrl) {
                CachedRemoteImage(url: url, targetSize: CGSize(width: 76, height: 76)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    C.surface
                }
            } else {
                Text(String((ch.name.first ?? "?").uppercased()))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.surface)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(Circle())
        .overlay { Circle().stroke(C.border, lineWidth: 2) }
    }

    // MARK: - Tab bar

    private func tabBar(_ ch: ChannelDetail, width: CGFloat) -> some View {
        let availableTabs = availableTabs(for: ch)
        let items = availableTabs.map { MediaverseTabItem(id: $0.id, label: $0.label) }

        return MediaverseUnderlineTabStrip(
            items: items,
            selectedID: activeTab.id,
            fillsWidth: true,
            verticalPadding: 10
        ) { id in
            guard let tab = availableTabs.first(where: { $0.id == id }) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTab = tab
            }
        }
        .frame(width: width)
    }

    private func availableTabs(for ch: ChannelDetail) -> [CTab] {
        var tabs: [CTab] = []
        if hasVideos(in: ch) { tabs.append(.videos) }
        if hasShorts { tabs.append(.shorts) }
        if hasPlaylists { tabs.append(.playlists) }
        tabs.append(.about)
        return tabs
    }

    private func hasVideos(in ch: ChannelDetail) -> Bool {
        !ch.videos.isEmpty
    }

    private var hasShorts: Bool {
        shorts?.isEmpty == false
    }

    private var hasPlaylists: Bool {
        playlists?.contains { $0._count.items > 0 } == true
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(_ ch: ChannelDetail) -> some View {
        switch activeTab {
        case .videos:
            if ch.videos.isEmpty {
                emptyState(icon: "video.fill", title: "No videos yet",
                           sub: "Videos uploaded to this channel will appear here.")
            } else {
                let cols = [GridItem(.flexible(minimum: 0), spacing: 12), GridItem(.flexible(minimum: 0), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(ch.videos) { v in
                        NavigationLink(value: AppRoute.video(v.id)) {
                            ChannelVideoCard(video: v)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case .shorts:
            if let s = shorts {
                if s.isEmpty {
                    emptyState(icon: "film.fill", title: "No shorts yet", sub: "")
                } else {
                    let cols = [GridItem(.flexible(minimum: 0), spacing: 12), GridItem(.flexible(minimum: 0), spacing: 12)]
                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(s) { v in
                            NavigationLink(value: AppRoute.short(v.id, showId: nil, channelId: ch.id)) {
                                ChannelShortCard(video: v)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ProgressView().tint(C.watch).frame(maxWidth: .infinity)
            }

        case .playlists:
            if let pl = playlists {
                let populatedPlaylists = pl.filter { $0._count.items > 0 }
                if populatedPlaylists.isEmpty {
                    emptyState(icon: "play.rectangle.on.rectangle", title: "No public playlists yet", sub: "")
                } else {
                    let cols = [GridItem(.flexible(minimum: 0), spacing: 12), GridItem(.flexible(minimum: 0), spacing: 12)]
                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(populatedPlaylists) { playlist in
                            NavigationLink(value: playlist.primaryRoute) {
                                ChannelPlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ProgressView().tint(C.watch).frame(maxWidth: .infinity)
            }

        case .about:
            channelAbout(ch)
        }
    }

    private func channelTabSwipeGesture(for ch: ChannelDetail) -> some Gesture {
        DragGesture(minimumDistance: 36, coordinateSpace: .local)
            .onEnded { value in
                switchChannelTab(for: value, channel: ch)
            }
    }

    private func switchChannelTab(for value: DragGesture.Value, channel ch: ChannelDetail) {
        let tabs = availableTabs(for: ch)
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let predictedHorizontal = value.predictedEndTranslation.width

        guard !(value.startLocation.x <= 36 && (horizontal > 0 || predictedHorizontal > 0)),
              abs(horizontal) > abs(vertical) * 1.4,
              abs(horizontal) > 70 || abs(predictedHorizontal) > 120,
              let currentIndex = tabs.firstIndex(of: activeTab)
        else { return }

        let nextIndex = horizontal < 0 ? currentIndex + 1 : currentIndex - 1
        guard tabs.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            activeTab = tabs[nextIndex]
        }
    }

    // MARK: - About tab

    private func channelAbout(_ ch: ChannelDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let desc = ch.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(C.text.opacity(0.80))
                    .lineSpacing(4)
            }
            let rows: [(String, String)] = [
                ("Handle",    "@\(ch.handle)"),
                ch.channelType.map { ("Type", $0.replacingOccurrences(of: "_", with: " ").capitalized) } ?? ("", ""),
                followerCount > 0 ? ("Followers", fmtCount(followerCount)) : ("", ""),
                !ch.videos.isEmpty ? ("Videos", "\(ch.videos.count)") : ("", ""),
                ("Joined", fmtJoined(ch.createdAt)),
            ].filter { !$0.0.isEmpty }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.0.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(C.textMuted)
                            .tracking(1.2)
                        Text(row.1)
                            .font(.subheadline)
                            .foregroundStyle(C.text.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            if !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    @MainActor
    private func load(showSpinner: Bool = true) async {
        if showSpinner,
           let snapshot = ChannelPageRenderCache.snapshot(for: handle) {
            channel = snapshot.0
            followStatus = snapshot.1
            shorts = snapshot.2
            playlists = snapshot.3
            activeTab = preferredChannelTab(for: snapshot.0, preserving: activeTab)
            isLoading = false
        } else if showSpinner {
            isLoading = true
        }
        loadError = nil

        do {
            channel = try await APIClient.shared.fetchChannel(handle: handle)
        } catch {
            if channel == nil {
                loadError = error.localizedDescription
                isLoading = false
            }
            return
        }

        if let ch = channel {
            activeTab = preferredChannelTab(for: ch, preserving: activeTab)
            storeCurrentChannelSnapshot()
            prefetchChannelImages(ch)
        }
        isLoading = false
        Task { await loadSecondaryChannelContent() }
    }

    @MainActor
    private func loadSecondaryChannelContent() async {
        guard let channel else { return }

        async let followTask = APIClient.shared.fetchChannelFollowStatus(handle: handle)
        async let shortsTask = APIClient.shared.fetchShorts(limit: 30, source: "channel", sourceId: channel.id)
        async let playlistTask = APIClient.shared.fetchChannelPlaylists(handle: handle)

        followStatus = try? await followTask
        let fetchedShorts = (try? await shortsTask)?.shorts ?? []
        shorts = fetchedShorts.filter { short in
            short.channelId == channel.id || short.channel?.id == channel.id
        }
        playlists = (try? await playlistTask) ?? []

        let nextTab = preferredChannelTab(for: channel, preserving: activeTab)
        if nextTab != activeTab {
            activeTab = nextTab
        }

        storeCurrentChannelSnapshot()
        prefetchChannelImages(channel)
    }

    @MainActor
    private func storeCurrentChannelSnapshot() {
        guard let channel else { return }
        ChannelPageRenderCache.store(
            channel: channel,
            followStatus: followStatus,
            shorts: shorts,
            playlists: playlists,
            handle: handle
        )
    }

    private func prefetchChannelImages(_ channel: ChannelDetail) {
        imagePrefetchTask?.cancel()

        let heroURLs = [channel.bannerUrl, channel.avatarUrl]
            .compactMap { C.mediaURL($0) }
        let payload = channelImagePrefetchPayload(for: activeTab, channel: channel)

        imagePrefetchTask = Task(priority: .utility) {
            if Task.isCancelled { return }
            await RemoteImageCache.shared.prefetch(
                urls: heroURLs,
                targetPixelSize: nil,
                limit: 2,
                concurrency: 2
            )
            if Task.isCancelled { return }
            await RemoteImageCache.shared.prefetch(
                urls: payload.urls,
                targetPixelSize: payload.targetSize,
                limit: payload.limit,
                concurrency: 2
            )
        }
    }

    private func channelImagePrefetchPayload(for tab: CTab, channel: ChannelDetail) -> (urls: [URL], targetSize: CGSize?, limit: Int) {
        switch tab {
        case .videos:
            return (
                channel.videos.prefix(6).compactMap { C.mediaURL($0.thumbnailUrl) },
                CGSize(width: 220, height: 124),
                6
            )
        case .shorts:
            return (
                (shorts ?? []).prefix(6).compactMap { C.mediaURL($0.thumbnailUrl) },
                CGSize(width: 180, height: 320),
                6
            )
        case .playlists:
            let urls = (playlists ?? [])
                .filter { $0._count.items > 0 }
                .prefix(4)
                .flatMap { $0.items.prefix(2).compactMap { C.mediaURL($0.video?.thumbnailUrl) } }
            return (Array(urls), CGSize(width: 120, height: 68), 8)
        case .about:
            return ([], nil, 0)
        }
    }

    private func preferredChannelTab(for channel: ChannelDetail, preserving current: CTab? = nil) -> CTab {
        let tabs = availableTabs(for: channel)
        if let current, tabs.contains(current), current != .about {
            return current
        }
        if tabs.contains(.videos) {
            return .videos
        }
        if tabs.contains(.shorts) {
            return .shorts
        }
        if tabs.contains(.playlists) {
            return .playlists
        }
        return .about
    }

    private var loadFailureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(C.textMuted)
            Text("Channel unavailable")
                .font(.headline)
                .foregroundStyle(C.text)
            Text(loadError ?? "This channel could not be loaded.")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, C.pagePad)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(C.watch)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleFollow(_ ch: ChannelDetail) async {
        guard !followLoading else { return }
        followLoading = true
        do {
            followStatus = try await APIClient.shared.toggleChannelFollow(handle: ch.handle)
            storeCurrentChannelSnapshot()
            NotificationCenter.default.post(name: .userFollowChanged, object: nil)
        } catch {}
        followLoading = false
    }

    private func toggleNotify(_ ch: ChannelDetail) async {
        guard !notifyLoading else { return }
        notifyLoading = true
        do {
            try await APIClient.shared.setChannelNotify(handle: ch.handle, on: !notifyOn)
            followStatus = FollowStatus(subscribed: isFollowing, count: followerCount, notifyOnPublish: !notifyOn)
            storeCurrentChannelSnapshot()
        } catch {}
        notifyLoading = false
    }

    // MARK: - Helpers

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func fmtJoined(_ iso: String) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        guard let date = df.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMMM yyyy"
        return out.string(from: date)
    }
}

// MARK: - ChannelVideoCard

private struct ChannelVideoCard: View {
    let video: ChannelDetail.VideoItem
    var isLocked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CachedRemoteImage(url: C.mediaURL(video.thumbnailUrl), targetSize: CGSize(width: 220, height: 124)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { C.surface }
                .frame(maxWidth: .infinity)
                .aspectRatio(C.mediaAspectRatio(forContentType: "video"), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                if isLocked {
                    Color.black.opacity(0.50)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.62))
                        .clipShape(Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                }

                if let dur = video.duration {
                    Text(fmtDuration(dur))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.70))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(video.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 4) {
                if video.views > 0 {
                    Text(fmtCount(video.views) + " views · ")
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
                Text(fmtAge(video.publishedAt ?? video.createdAt))
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private func fmtDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func fmtAge(_ iso: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        guard let d = df.date(from: iso) else { return "" }
        let days = Int(Date().timeIntervalSince(d) / 86400)
        if days == 0 { return "Today" }
        if days < 7  { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }
}

// MARK: - ChannelShortCard

private struct ChannelShortCard: View {
    let video: Short
    var isLocked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                CachedRemoteImage(url: C.mediaURL(video.thumbnailUrl), targetSize: CGSize(width: 180, height: 320)) { img in
                    img.resizable().scaledToFill()
                } placeholder: { C.surface }
                .frame(maxWidth: .infinity)
                .aspectRatio(C.mediaAspectRatio(forContentType: "short"), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                if isLocked {
                    Color.black.opacity(0.50)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.62))
                        .clipShape(Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                }

                if let dur = video.duration {
                    Text(fmtDuration(dur))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.70))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(video.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if video.views > 0 {
                Text("\(fmtCount(video.views)) views")
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private func fmtDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - ChannelPlaylistCard

private struct ChannelPlaylistCard: View {
    let playlist: ChannelPlaylist

    private var thumbnails: [String] {
        playlist.items.compactMap { $0.video?.thumbnailUrl }
    }
    private var count: Int { playlist._count.items }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                mosaicThumbnail
                    .aspectRatio(C.mediaAspectRatio(forContentType: playlist.type), contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.68)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                playlistCountBadge
                    .padding(8)
            }
            .aspectRatio(C.mediaAspectRatio(forContentType: playlist.type), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 34, alignment: .topLeading)

                HStack(spacing: 5) {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "play.rectangle.on.rectangle")
                        .frame(width: 11, height: 11)
                    Text("Playlist")
                    Text("·")
                    Text("\(count)")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var playlistCountBadge: some View {
        let itemName = playlist.type == "short" ? "short" : "video"

        return Text("\(count) \(itemName)\(count == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var mosaicThumbnail: some View {
        let visibleThumbs = Array(thumbnails.prefix(4))

        if visibleThumbs.count >= 4 {
            GeometryReader { geo in
                let cellWidth = geo.size.width / 2
                let cellHeight = geo.size.height / 2

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mosaicImage(visibleThumbs[0])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(visibleThumbs[1])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: 0) {
                        mosaicImage(visibleThumbs[2])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(visibleThumbs[3])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
        } else if let t = visibleThumbs.first {
            mosaicImage(t)
        } else {
            C.surface
                .overlay {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(C.textMuted)
                }
        }
    }

    private func mosaicImage(_ url: String) -> some View {
        CachedRemoteImage(url: C.mediaURL(url), targetSize: CGSize(width: 120, height: 68)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            C.surface
        }
        .clipped()
    }
}

extension ChannelPlaylist {
    var primaryRoute: AppRoute {
        if let firstVideoId = items.first?.video?.id {
            return .video(firstVideoId)
        }
        return .playlist(id)
    }
}
