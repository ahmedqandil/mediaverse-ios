import SwiftUI

/// Full-screen search: typeahead suggestions → full results with 4 sections.
/// Mirrors /src/app/search/page.tsx
private struct SearchHistoryItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let type: String
    let targetId: String
    let showId: String?
    let channelId: String?

    var iconName: String {
        switch type {
        case "channel": return "person.3"
        case "show": return "tv"
        case "episode": return "film"
        case "short": return "play.rectangle.on.rectangle"
        case "video": return "play.rectangle"
        default: return "magnifyingglass"
        }
    }

    var route: AppRoute? {
        switch type {
        case "channel": return .channel(targetId)
        case "show": return .show(targetId)
        case "episode": return .episode(targetId)
        case "short": return .short(targetId, showId: showId, channelId: channelId)
        case "video": return .video(targetId)
        default: return nil
        }
    }
}

struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var query      = ""
    @State private var suggests   = [SuggestItem]()
    @State private var results    = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
    @State private var showResults = false
    @State private var isLoading  = false
    @State private var suggestionRoute: AppRoute?
    @AppStorage("searchHistory") private var searchHistoryData = "[]"

    @FocusState private var focused: Bool

    // Debounce timer
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                    Divider().background(C.border)

                    if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                        emptyPrompt
                    } else if showResults {
                        resultsView
                    } else {
                        suggestionsView
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $suggestionRoute) { route in
                routeDestination(route)
            }
        }
        .onAppear { focused = true }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(C.textMuted)
                    .font(.system(size: 15, weight: .semibold))

                TextField("Search videos, shows, channels...", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(C.text)
                    .onSubmit { Task { await runFullSearch() } }
                    .onChange(of: query) { _, newVal in
                        debounceTask?.cancel()
                        showResults = false
                        if newVal.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { suggests = []; return }
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            await runSuggest(q: newVal)
                        }
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        suggests = []
                        showResults = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(C.elevated)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(C.border.opacity(0.85), lineWidth: 1) }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            Button("Cancel") { dismiss() }
                .foregroundStyle(C.watch)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .background(C.bg)
    }

    // MARK: - Suggestions

    private var suggestionsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggests) { item in
                    Button {
                        activateSuggestion(item)
                    } label: {
                        HStack(spacing: 12) {
                            // Type icon
                            Image(systemName: iconFor(item.type))
                                .font(.system(size: 14))
                                .foregroundStyle(C.textMuted)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(C.text)
                                    .lineLimit(1)
                                if let meta = item.meta {
                                    Text(meta)
                                        .font(.caption2)
                                        .foregroundStyle(C.textMuted)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption2)
                                .foregroundStyle(C.textMuted)
                        }
                        .padding(.horizontal, C.pagePad)
                        .padding(.vertical, 12)
                    }
                    Divider()
                        .background(C.border)
                        .padding(.leading, C.pagePad + 32)
                }
            }
        }
    }

    // MARK: - Full results

    private var resultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if isLoading {
                    ProgressView()
                        .tint(C.watch)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }

                // Channels — horizontal compact row
                if let channels = results.channels, !channels.isEmpty {
                    resultSection("Channels") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(channels) { ch in
                                    Button {
                                        openSearchItem(
                                            title: ch.name,
                                            subtitle: ch.followerCount.map { "\($0) followers" },
                                            type: "channel",
                                            route: .channel(ch.handle ?? ch.id)
                                        )
                                    } label: {
                                        VStack(spacing: 6) {
                                            AsyncImage(url: C.mediaURL(ch.avatarUrl)) { img in
                                                img.resizable().scaledToFill()
                                            } placeholder: {
                                                Color.white.opacity(0.08)
                                            }
                                            .frame(width: 56, height: 56)
                                            .clipShape(Circle())

                                            Text(ch.name)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(C.text)
                                                .lineLimit(1)
                                                .frame(width: 64)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, C.pagePad)
                        }
                    }
                }

                // Shows — 2:3 portrait grid
                if let shows = results.shows, !shows.isEmpty {
                    resultSection("Shows") {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 12
                        ) {
                            ForEach(shows) { show in
                                Button {
                                    openSearchItem(
                                        title: show.title,
                                        subtitle: show.genre,
                                        type: "show",
                                        route: .show(show.id)
                                    )
                                } label: {
                                    ShowPortraitCard(show: show)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, C.pagePad)
                    }
                }

                // Episodes — list rows
                if let episodes = results.episodes, !episodes.isEmpty {
                    resultSection("Episodes") {
                        LazyVStack(spacing: 0) {
                            ForEach(episodes) { ep in
                                Button {
                                    openSearchItem(
                                        title: ep.title,
                                        subtitle: ep.season?.show?.title,
                                        type: "episode",
                                        route: .episode(ep.id)
                                    )
                                } label: {
                                    EpisodeSearchRow(ep: ep)
                                }
                                .buttonStyle(.plain)
                                Divider()
                                    .background(C.border)
                                    .padding(.leading, C.pagePad + 64)
                            }
                        }
                    }
                }

                // Videos — horizontal cards
                if let videos = results.videos, !videos.isEmpty {
                    resultSection("Videos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(videos) { video in
                                    let route = AppRoute.media(id: video.id, type: video.type, channelId: video.channel?.id)
                                    Button {
                                        openSearchItem(
                                            title: video.title,
                                            subtitle: video.channel?.name,
                                            type: video.type?.lowercased() == "short" ? "short" : "video",
                                            route: route
                                        )
                                    } label: {
                                        VideoSearchCard(video: video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, C.pagePad)
                        }
                    }
                }

                let hasAny = !(results.channels?.isEmpty ?? true) ||
                             !(results.shows?.isEmpty ?? true) ||
                             !(results.episodes?.isEmpty ?? true) ||
                             !(results.videos?.isEmpty ?? true)
                if !isLoading && !hasAny {
                    noResultsView
                }
            }
            .padding(.top, 20)
        }
    }

    // MARK: - Section header helper

    @ViewBuilder
    private func resultSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(C.text)
                .padding(.horizontal, C.pagePad)
            content()
        }
    }

    // MARK: - Empty / no results

    private var emptyPrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(C.textMuted.opacity(0.75))
                    Text("Search videos, shows, channels, and more")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 44)

                if !searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent searches")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(C.text)
                            Spacer()
                            Button("Clear") {
                                clearSearchHistory()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.watch)
                        }

                        LazyVStack(spacing: 8) {
                            ForEach(searchHistory) { item in
                                Button {
                                    openHistoryItem(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.iconName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(C.textMuted)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(C.text)
                                                .lineLimit(1)
                                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(C.textMuted)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(C.textMuted.opacity(0.65))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 48)
                                    .background(C.surface.opacity(0.9))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                }
            }
            .padding(.bottom, 28)
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("No results for \"\(query)\"")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            Text("Try different keywords")
                .font(.caption)
                .foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private var searchHistory: [SearchHistoryItem] {
        guard let data = searchHistoryData.data(using: .utf8),
              let items = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    private func addSearchHistory(_ item: SearchHistoryItem) {
        var items = searchHistory.filter { $0.id != item.id }
        items.insert(item, at: 0)
        items = Array(items.prefix(10))
        if let data = try? JSONEncoder().encode(items), let value = String(data: data, encoding: .utf8) {
            searchHistoryData = value
        }
    }

    private func clearSearchHistory() {
        searchHistoryData = "[]"
    }

    private func runSuggest(q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        do {
            suggests = try await APIClient.shared.searchSuggest(q: trimmed)
        } catch { suggests = [] }
    }

    private func runFullSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        isLoading  = true
        showResults = true
        suggests   = []
        do {
            results = try await APIClient.shared.search(q: trimmed)
        } catch {}
        isLoading = false
    }

    private func activateSuggestion(_ item: SuggestItem) {
        if let route = route(for: item.href) {
            openSearchItem(title: item.title, subtitle: item.meta, type: item.type, route: route)
            return
        }
        query = item.title
        Task { await runFullSearch() }
    }

    private func openSearchItem(title: String, subtitle: String?, type: String, route: AppRoute) {
        let item = historyItem(title: title, subtitle: subtitle, type: type, route: route)
        addSearchHistory(item)
        suggestionRoute = route
    }

    private func openHistoryItem(_ item: SearchHistoryItem) {
        guard let route = item.route else { return }
        addSearchHistory(item)
        suggestionRoute = route
    }

    private func historyItem(title: String, subtitle: String?, type: String, route: AppRoute) -> SearchHistoryItem {
        let normalizedType: String
        let targetId: String
        let showId: String?
        let channelId: String?

        switch route {
        case .video(let id):
            normalizedType = "video"
            targetId = id
            showId = nil
            channelId = nil
        case .short(let id, let routeShowId, let routeChannelId):
            normalizedType = "short"
            targetId = id
            showId = routeShowId
            channelId = routeChannelId
        case .episode(let id):
            normalizedType = "episode"
            targetId = id
            showId = nil
            channelId = nil
        case .channel(let id):
            normalizedType = "channel"
            targetId = id
            showId = nil
            channelId = nil
        case .show(let id):
            normalizedType = "show"
            targetId = id
            showId = nil
            channelId = nil
        default:
            normalizedType = type
            targetId = route.id
            showId = nil
            channelId = nil
        }

        return SearchHistoryItem(
            id: "\(normalizedType)-\(targetId)",
            title: title,
            subtitle: subtitle,
            type: normalizedType,
            targetId: targetId,
            showId: showId,
            channelId: channelId
        )
    }

    private func route(for href: String) -> AppRoute? {
        let path: String
        if let url = URL(string: href), let host = url.host, !host.isEmpty {
            path = url.path
        } else {
            path = href
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" {
            return .episode(parts[2])
        }
        if parts.count >= 2, parts[0] == "watch" {
            return .video(parts[1])
        }
        if parts.count >= 2, parts[0] == "shows" {
            return .show(parts[1])
        }
        if parts.count >= 2, parts[0] == "channel" {
            return .channel(parts[1])
        }
        if parts.count >= 2, parts[0] == "channels" {
            return .channel(parts[1])
        }
        if parts.count >= 2, parts[0] == "playlist" {
            return .playlist(parts[1])
        }
        if parts.count >= 2, parts[0] == "playlists" {
            return .playlist(parts[1])
        }
        if parts.count >= 2, parts[0] == "collections" {
            return .collection(parts[1])
        }
        if parts.count >= 2, parts[0] == "microdramas" {
            return .microdramaShow(parts[1])
        }
        return nil
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id): VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id): EpisodeWatchView(episodeId: id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "channel":  return "person.3"
        case "show":     return "tv"
        case "video":    return "play.rectangle"
        case "episode":  return "film"
        default:         return "magnifyingglass"
        }
    }
}

// MARK: - Sub-components

private struct ShowPortraitCard: View {
    let show: SearchResultShow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(show.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
        }
    }
}

private struct EpisodeSearchRow: View {
    let ep: SearchResultEpisode
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: C.mediaURL(ep.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                if let sNum = ep.season?.seasonNumber, let eNum = ep.episodeNumber {
                    Text("S\(sNum) · E\(eNum)")
                        .font(.caption2)
                        .foregroundStyle(C.watch)
                }
                Text(ep.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let showTitle = ep.season?.show?.title {
                    Text(showTitle)
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
    }
}

private struct VideoSearchCard: View {
    let video: SearchResultVideo
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: C.mediaURL(video.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(video.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 160, alignment: .leading)

            if let ch = video.channel {
                Text(ch.name)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 160)
    }
}
