import SwiftUI
import AVKit

/// Microdrama series detail page — episode list with access badges.
/// Mirrors /src/app/microdramas/[showId]/MicrodramaShowClient.tsx
struct MicrodramaShowView: View {

    private enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case videos = "Videos"
        case shorts = "Shorts"
        case allVideos = "All Videos"
        case playlists = "Playlists"
        case about = "About"

        var id: String { rawValue }
    }

    let showId: String

    @Environment(\.dismiss) private var dismiss

    @State private var show: MicrodramaShowDetail?
    @State private var episodes = [MicrodramaEpisode]()
    @State private var clips = [ShowClip]()
    @State private var shorts = [Short]()
    @State private var playlists = [ChannelPlaylist]()
    @State private var config: MicrodramaConfig?
    @State private var selectedTab: DetailTab = .episodes
    @State private var isLoading = true
    @State private var errorMsg: String?

    private var videoClips: [ShowClip] {
        clips.filter { $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "short" }
    }

    private var shortClips: [ShowClip] {
        clips.filter { $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" }
    }

    private var allVideoCount: Int {
        videoClips.count + shortClips.count + shorts.count
    }

    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if !episodes.isEmpty { tabs.append(.episodes) }
        if !videoClips.isEmpty { tabs.append(.videos) }
        if !shorts.isEmpty || !shortClips.isEmpty { tabs.append(.shorts) }
        if allVideoCount > 0 { tabs.append(.allVideos) }
        if !playlists.isEmpty { tabs.append(.playlists) }
        tabs.append(.about)
        return tabs
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(C.watch)
            } else if let err = errorMsg {
                errorState(err)
            } else if let show {
                content(show)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .enablesInteractiveSwipeBack()
        .task { await load() }
    }

    // MARK: - Main content

    private func content(_ show: MicrodramaShowDetail) -> some View {
        GeometryReader { proxy in
            let pageWidth = proxy.size.width
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(show, width: pageWidth)
                        showDescription(show)
                            .frame(width: pageWidth)
                        tabStrip
                            .frame(width: pageWidth)

                        Group {
                            switch selectedTab {
                            case .episodes:
                                episodesSection
                            case .videos:
                                videosSection
                            case .shorts:
                                shortsSection
                            case .allVideos:
                                allVideosSection
                            case .playlists:
                                playlistsSection
                            case .about:
                                aboutSection(show)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                    .frame(width: pageWidth, alignment: .topLeading)
                }
                .ignoresSafeArea(edges: .top)

                heroBackButton
                    .padding(.leading, 16)
                    .padding(.top, max(12, topInset - 6))
            }
        }
    }

    private var tabStrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(availableTabs) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTab = tab
                                reader.scrollTo(tab.id, anchor: .center)
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selectedTab == tab ? C.text : C.textMuted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if selectedTab == tab {
                                        Rectangle()
                                            .fill(C.watch)
                                            .frame(height: 2)
                                            .offset(y: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
            .frame(height: 46)
        }
        .frame(height: 46)
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Divider().background(C.border)
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessLines
            sectionHeader("Episodes", count: episodes.count)

            if episodes.isEmpty {
                emptyTabState(icon: "play.rectangle", title: "No episodes yet", message: "Episodes for this microdrama will appear here.")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(episodes) { ep in
                        EpisodeAccessRow(ep: ep, showId: showId, config: config)
                    }
                }
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var videosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Videos", count: videoClips.count)
            if videoClips.isEmpty {
                emptyTabState(icon: "play.rectangle", title: "No videos yet", message: "Videos linked to this microdrama will appear here.")
            } else {
                mediaGrid {
                    ForEach(videoClips) { clip in
                        NavigationLink(value: AppRoute.video(clip.id)) {
                            MicrodramaClipCard(clip: clip)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var shortsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Shorts", count: shortClips.count + shorts.count)
            if shortClips.isEmpty && shorts.isEmpty {
                emptyTabState(icon: "bolt.fill", title: "No shorts yet", message: "Shorts from this microdrama will appear here.")
            } else {
                mediaGrid {
                    ForEach(shortClips) { clip in
                        NavigationLink(value: AppRoute.short(clip.id, showId: showId, channelId: nil)) {
                            MicrodramaClipCard(clip: clip, style: .short)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(shorts) { short in
                        NavigationLink(value: AppRoute.short(short.id, showId: showId, channelId: short.channelId)) {
                            MicrodramaShortCard(short: short)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var allVideosSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if allVideoCount == 0 {
                emptyTabState(icon: "rectangle.stack", title: "No videos yet", message: "Videos and shorts will appear here.")
                    .padding(.horizontal, C.pagePad)
            } else {
                if !videoClips.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        tabGroupTitle("Videos")
                        mediaGrid {
                            ForEach(videoClips) { clip in
                                NavigationLink(value: AppRoute.video(clip.id)) {
                                    MicrodramaClipCard(clip: clip)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, C.pagePad)
                    }
                }

                if !shortClips.isEmpty || !shorts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        tabGroupTitle("Shorts")
                        mediaGrid {
                            ForEach(shortClips) { clip in
                                NavigationLink(value: AppRoute.short(clip.id, showId: showId, channelId: nil)) {
                                    MicrodramaClipCard(clip: clip, style: .short)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(shorts) { short in
                                NavigationLink(value: AppRoute.short(short.id, showId: showId, channelId: short.channelId)) {
                                    MicrodramaShortCard(short: short)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, C.pagePad)
                    }
                }
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Playlists", count: playlists.count)
            if playlists.isEmpty {
                emptyTabState(icon: "list.bullet.rectangle", title: "No playlists yet", message: "Curated playlists for this microdrama will appear here.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: AppRoute.playlist(playlist.id)) {
                            MicrodramaPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(C.text)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(C.textMuted)
        }
    }

    private func tabGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(C.textMuted)
            .tracking(1.2)
            .padding(.horizontal, C.pagePad)
    }

    private func mediaGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
            content()
        }
    }

    private func emptyTabState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(C.textMuted.opacity(0.7))
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(C.text)
            Text(message)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func aboutSection(_ show: MicrodramaShowDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let description = show.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Story")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(C.text)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Details")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(C.text)

                detailGrid(show)
            }

            if !show.tags.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tags")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(C.text)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(show.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(C.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }

            accessLines
        }
        .padding(.horizontal, C.pagePad)
    }

    private func detailGrid(_ show: MicrodramaShowDetail) -> some View {
        VStack(spacing: 8) {
            detailRow("Episodes", "\(episodes.count)")
            detailRow("Status", show.status.capitalized)
            detailRow("Type", show.showType.capitalized)
            if let genre = show.genre { detailRow("Genre", genre) }
            if let language = show.language { detailRow("Language", language.uppercased()) }
            if let country = show.country { detailRow("Country", country.uppercased()) }
            if let studio = show.studio { detailRow("Studio", studio) }
            if let rating = show.contentRating { detailRow("Rating", rating) }
            if let networkName = show.network?.name { detailRow("Network", networkName) }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.textMuted)
            Spacer(minLength: 16)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Hero

    private var heroBackButton: some View {
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

    private func hero(_ show: MicrodramaShowDetail, width: CGFloat) -> some View {
        let heroHeight: CGFloat = 320

        return ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(
                url: C.mediaURL(show.bannerUrl ?? show.coverUrl),
                targetSize: CGSize(width: width, height: heroHeight)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [C.surface, C.bg], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: width)
            .frame(height: heroHeight)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.6), .black.opacity(0.10)],
                startPoint: .bottom,
                endPoint: .init(x: 0.5, y: 0.45)
            )
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.35)
            )

            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                HStack(spacing: 8) {
                    metaBadge("Microdrama", style: .accent)
                    if let genre = show.genre, !genre.isEmpty {
                        metaBadge(genre, style: .muted)
                    }
                    if let language = show.language, !language.isEmpty {
                        metaBadge(language.uppercased(), style: .muted)
                    }
                }

                Text(show.title)
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .shadow(color: .black.opacity(0.6), radius: 4)

                NavigationLink(value: AppRoute.microdramaWatch(showId)) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Watch Now")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(C.watch)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, C.pagePad)
            .padding(.bottom, 24)
            .frame(width: width, height: heroHeight, alignment: .bottomLeading)
        }
        .frame(width: width)
        .frame(height: heroHeight)
        .clipped()
    }

    private enum MicrodramaBadgeStyle { case accent, muted }

    private func metaBadge(_ text: String, style: MicrodramaBadgeStyle) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(style == .accent ? C.watch : C.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style == .accent ? C.watch.opacity(0.12) : .white.opacity(0.08))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func showDescription(_ show: MicrodramaShowDetail) -> some View {
        if let description = show.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(C.text.opacity(0.82))
                .lineLimit(3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, C.pagePad)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.bg)
        }
    }

    // MARK: - Access summary lines

    @ViewBuilder
    private var accessLines: some View {
        if let cfg = config {
            VStack(alignment: .leading, spacing: 4) {
                if cfg.freeEpisodeCount > 0 {
                    Label("First \(cfg.freeEpisodeCount) episode\(cfg.freeEpisodeCount > 1 ? "s" : "") are free",
                          systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(hex: "#10B981"))
                }
            }
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        errorMsg = nil
        do {
            async let episodeResponse = APIClient.shared.fetchMicrodramaEpisodes(showId: showId)
            async let clipResponse = APIClient.shared.fetchShowClips(id: showId)
            async let playlistResponse = APIClient.shared.fetchShowPlaylists(id: showId)
            async let shortsResponse = APIClient.shared.fetchShorts(feed: "recommended", limit: 24, source: "show", sourceId: showId)

            let resp = try await episodeResponse
            show = resp.show
            config = resp.config
            episodes = resp.episodes
            clips = (try? await clipResponse) ?? []
            playlists = (try? await playlistResponse) ?? []
            let fetchedShorts = try? await shortsResponse
            shorts = fetchedShorts?.shorts ?? []
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(C.textMuted)
            Text(msg).foregroundStyle(C.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Media cards

private struct MicrodramaClipCard: View {
    enum Style { case video, short }

    let clip: ShowClip
    var style: Style = .video

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            mediaThumb(url: clip.thumbnailUrl, aspectRatio: style == .short ? 9 / 16 : 16 / 9)
            Text(clip.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let duration = clip.duration {
                    Text(formatDuration(duration))
                }
                if clip.views > 0 {
                    Text("\(clip.views) views")
                }
            }
            .font(.caption2)
            .foregroundStyle(C.textMuted)
        }
    }
}

private struct MicrodramaShortCard: View {
    let short: Short

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            mediaThumb(url: short.thumbnailUrl, aspectRatio: 9 / 16)
            Text(short.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let duration = short.duration {
                    Text(formatDuration(duration))
                }
                if short.views > 0 {
                    Text("\(short.views) views")
                }
            }
            .font(.caption2)
            .foregroundStyle(C.textMuted)
        }
    }
}

private struct MicrodramaUnifiedRow: View {
    let kind: String
    let title: String
    let thumbnailUrl: String?
    let duration: Double?

    var body: some View {
        HStack(spacing: 12) {
            mediaThumb(url: thumbnailUrl, aspectRatio: kind == "Short" || kind == "Episode" ? 9 / 16 : 16 / 9)
                .frame(width: kind == "Short" || kind == "Episode" ? 58 : 92)
            VStack(alignment: .leading, spacing: 5) {
                Text(kind.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(C.watch)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let duration {
                    Text(formatDuration(duration))
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(C.textMuted)
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MicrodramaPlaylistRow: View {
    let playlist: ChannelPlaylist

    var body: some View {
        HStack(spacing: 12) {
            playlistMosaic
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }
                Text("\(playlist._count.items) items · \(playlist.type.capitalized)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.textMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(C.textMuted)
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var playlistMosaic: some View {
        let urls = playlist.items.prefix(4).map { $0.video?.thumbnailUrl }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(0..<4, id: \.self) { index in
                if urls.indices.contains(index), let url = urls[index], let mediaURL = C.mediaURL(url) {
                    CachedRemoteImage(
                        url: mediaURL,
                        targetSize: CGSize(width: 120, height: 68)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                } else {
                    Color.white.opacity(0.08)
                }
            }
        }
    }
}

private func mediaThumb(url: String?, aspectRatio: CGFloat) -> some View {
    Group {
        if let mediaURL = C.mediaURL(url) {
            CachedRemoteImage(
                url: mediaURL,
                targetSize: CGSize(width: 160, height: 160 / aspectRatio)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
        } else {
            Color.white.opacity(0.08)
        }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private func formatDuration(_ s: Double) -> String {
    let m = Int(s) / 60
    let sec = Int(s) % 60
    return "\(m):\(String(format: "%02d", sec))"
}

// MARK: - Episode row

private struct EpisodeAccessRow: View {
    let ep: MicrodramaEpisode
    let showId: String
    let config: MicrodramaConfig?

    private var canPlay: Bool {
        (ep.accessState == "free" || ep.accessState == "svod" || ep.accessState == "ppv") && ep.videoUrl != nil
    }

    var body: some View {
        NavigationLink(value: AppRoute.microdramaWatchEp(showId, ep.episodeNumber)) {
            HStack(spacing: 12) {
                ZStack(alignment: .center) {
                    CachedRemoteImage(
                        url: C.mediaURL(ep.thumbnailUrl),
                        targetSize: CGSize(width: 74, height: 112)
                    ) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.06)
                        Text("\(ep.episodeNumber)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.white.opacity(0.25))
                    }
                    .frame(width: 74, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if !canPlay {
                        Color.black.opacity(0.34)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 74, height: 112)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Episode \(ep.episodeNumber)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(C.watch)

                    Text(ep.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canPlay ? C.text : C.textMuted)
                        .lineLimit(2)

                    if let description = ep.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let dur = ep.duration {
                            Text(formatDuration(dur))
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                }

                Spacer(minLength: 8)

                Image(systemName: canPlay ? "play.circle.fill" : "lock.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(canPlay ? C.watch : .white.opacity(0.46))
            }
            .padding(10)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
            .opacity(canPlay ? 1 : 0.68)
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}
