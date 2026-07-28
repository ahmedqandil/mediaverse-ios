import SwiftUI
import Network

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
        case "person": return "person.crop.circle"
        case "vibe": return "person.3.fill"
        case "ripple": return "wave.3.right"
        case "collection": return "rectangle.stack.fill"
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
        case "person": return .atmo(targetId)
        case "vibe": return .vibe(targetId)
        case "ripple": return .ripple(targetId)
        case "collection": return .collection(targetId)
        default: return nil
        }
    }
}

private struct SuggestionSection: Identifiable {
    let id: String
    let title: String
    let items: [SuggestItem]
}

private enum SearchFilter: String, CaseIterable, Identifiable {
    case all
    case shows
    case videos
    case channels
    case episodes
    case people
    case vibes
    case ripples
    case collections

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .shows: return "Shows"
        case .videos: return "Videos"
        case .channels: return "Channels"
        case .episodes: return "Episodes"
        case .people: return "People"
        case .vibes: return "Vibes"
        case .ripples: return "Ripples"
        case .collections: return "Collections"
        }
    }
}

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var committedQuery = ""
    @State private var suggests = [SuggestItem]()
    @State private var trending = [SuggestItem]()
    @State private var results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
    @State private var showResults = false
    @State private var isLoadingSuggest = false
    @State private var isLoadingResults = false
    @State private var searchError: String?
    @State private var isOffline = false
    @State private var activeFilter: SearchFilter = .all
    @State private var suggestionRoute: AppRoute?
    @State private var selectedSuggestionID: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var networkMonitor: NWPathMonitor?
    @State private var suggestGeneration = 0
    @State private var trendingGeneration = 0
    @State private var searchGeneration = 0
    @AppStorage("searchHistory") private var searchHistoryData = "[]"
    @FocusState private var focused: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSuggestionItems: [SuggestItem] {
        guard !showResults else { return [] }
        let source = trimmedQuery.isEmpty ? trending : suggests
        return suggestionSections(items: source).flatMap { Array($0.items.prefix(8)) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchBar
                    if isOffline { offlineBanner }
                    Divider().background(C.border)

                    if showResults {
                        resultsView
                    } else if trimmedQuery.isEmpty {
                        focusStateView
                    } else if trimmedQuery.count == 1 {
                        suggestionsContainer(showKeepTyping: false)
                    } else {
                        suggestionsContainer(showKeepTyping: false)
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $suggestionRoute) { route in
                routeDestination(route)
            }
        }
        .focusable()
        .onKeyPress(.downArrow) {
            moveSuggestionSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSuggestionSelection(by: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            focused = true
            startNetworkMonitor()
            Task {
                await loadRemoteSearchHistoryIfNeeded()
                await loadTrendingIfNeeded()
                if trimmedQuery.count >= 2, !showResults {
                    await runFullSearch()
                }
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            suggestGeneration &+= 1
            trendingGeneration &+= 1
            searchGeneration &+= 1
            stopNetworkMonitor()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isLoadingSuggest ? "circle.dotted" : "magnifyingglass")
                    .foregroundStyle(C.textMuted)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)

                TextField("Search Westreem…", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(C.text)
                    .disabled(isOffline)
                    .accessibilityLabel("Search Westreem")
                    .onSubmit { submitActiveSuggestionOrSearch() }
                    .onChange(of: query) { oldValue, newValue in
                        handleQueryChange(oldValue: oldValue, newValue: newValue)
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        suggests = []
                        showResults = false
                        searchError = nil
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
            .onTapGesture {
                focused = true
                Task { await loadTrendingIfNeeded() }
            }

            Button("Cancel") { dismiss() }
                .foregroundStyle(C.watch)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .background(C.bg)
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You appear to be offline")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, C.pagePad)
        .frame(height: 34)
        .background(Color(hex: "#FBBF24"))
    }

    private var focusStateView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !searchHistory.isEmpty {
                    historySection
                }
                if !trending.isEmpty {
                    suggestionListSection(
                        title: "Trending",
                        icon: "chart.line.uptrend.xyaxis",
                        items: trending,
                        queryForHighlight: nil
                    )
                } else {
                    emptyPrompt
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

    private func suggestionsContainer(showKeepTyping: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if showKeepTyping {
                    statusRow("Keep typing…")
                } else if isLoadingSuggest && suggests.isEmpty {
                    statusRow("Searching…", showsSpinner: true)
                } else if suggests.isEmpty {
                    noSuggestionResults
                } else {
                    ForEach(suggestionSections(items: suggests)) { section in
                        suggestionListSection(
                            title: section.title,
                            icon: nil,
                            items: section.items,
                            queryForHighlight: trimmedQuery
                        )
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Searches")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(C.text)
                Spacer()
                Button("Clear all") { clearSearchHistory() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.watch)
            }
            .padding(.horizontal, C.pagePad)

            LazyVStack(spacing: 0) {
                ForEach(searchHistory) { item in
                    HStack(spacing: 12) {
                        Button { openHistoryItem(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.iconName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(C.textMuted)
                                    .frame(width: 22)
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
                            }
                        }
                        .buttonStyle(.plain)

                        Button { removeSearchHistory(item) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, C.pagePad)
                    .frame(minHeight: 50)
                }
            }
        }
    }

    private func suggestionListSection(title: String, icon: String?, items: [SuggestItem], queryForHighlight: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.watch)
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, C.pagePad)

            LazyVStack(spacing: 0) {
                ForEach(Array(items.prefix(8))) { item in
                    Button { activateSuggestion(item) } label: {
                        suggestionRow(
                            item,
                            queryForHighlight: queryForHighlight,
                            isSelected: selectedSuggestionID == item.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title), \(badgeLabel(for: item.type))")
                    .accessibilityHint("Double tap to open")

                    Divider()
                        .background(C.border)
                        .padding(.leading, C.pagePad + 62)
                }
            }
        }
    }

    private func suggestionRow(_ item: SuggestItem, queryForHighlight: String?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            suggestionAvatar(item)
            VStack(alignment: .leading, spacing: 4) {
                highlightedTitle(item.title, query: queryForHighlight)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                if let meta = item.meta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            typeBadge(item.type)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .background(isSelected ? C.watch.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(C.watch)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func suggestionAvatar(_ item: SuggestItem) -> some View {
        let type = item.type.lowercased()
        let size: CGFloat = type == "channel" ? 42 : 54
        let aspect = suggestionAspectRatio(for: type)

        if type == "channel" {
            ZStack {
                if let url = C.mediaURL(item.imageUrl) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: size, height: size)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder(title: item.title, type: type)
                    }
                } else {
                    placeholder(title: item.title, type: type)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            ZStack {
                if let url = C.mediaURL(item.imageUrl) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: size * aspect, height: size)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder(title: item.title, type: type)
                    }
                } else {
                    placeholder(title: item.title, type: type)
                }
            }
            .frame(width: size * aspect, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
    }

    private func placeholder(title: String, type: String) -> some View {
        ZStack {
            Color.white.opacity(0.07)
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(C.textMuted)
        }
    }

    private func highlightedTitle(_ title: String, query: String?) -> Text {
        guard let query,
              !query.isEmpty,
              let range = title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(title)
        }
        return Text(String(title[..<range.lowerBound]))
            + Text(String(title[range])).bold()
            + Text(String(title[range.upperBound...]))
    }

    private func typeBadge(_ type: String) -> some View {
        Text(badgeLabel(for: type))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.82))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(badgeColor(for: type), in: Capsule())
            .accessibilityHidden(true)
    }

    private var noSuggestionResults: some View {
        VStack(spacing: 12) {
            statusRow("No results for \"\(trimmedQuery)\"")
            Button { submitSearchAnyway() } label: {
                Label("Search anyway", systemImage: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(C.watch)
            .disabled(trimmedQuery.count < 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private var emptyPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(C.textMuted.opacity(0.75))
            Text("Search shows, channels, videos, and more")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private func statusRow(_ text: String, showsSpinner: Bool = false) -> some View {
        HStack(spacing: 10) {
            if showsSpinner { ProgressView().tint(C.watch) }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(C.textMuted)
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 12)
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                filterTabs

                if isLoadingResults {
                    skeletonResults
                } else if let searchError {
                    errorView(searchError)
                } else if results.isEmpty {
                    noResultsView
                } else {
                    if let channels = results.channels, !channels.isEmpty { channelsResults(channels) }
                    if let shows = results.shows, !shows.isEmpty { showsResults(shows) }
                    if let episodes = results.episodes, !episodes.isEmpty { episodesResults(episodes) }
                    if let videos = results.videos, !videos.isEmpty { videosResults(videos) }
                    if let people = results.people, !people.isEmpty { peopleResults(people) }
                    if let vibes = results.vibes, !vibes.isEmpty { vibesResults(vibes) }
                    if let ripples = results.ripples, !ripples.isEmpty { ripplesResults(ripples) }
                    if let collections = results.collections, !collections.isEmpty { collectionsResults(collections) }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
    }

    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { filter in
                    Button {
                        activeFilter = filter
                        Task { await runFullSearch() }
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(activeFilter == filter ? .black : C.text)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(activeFilter == filter ? C.watch : C.elevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, C.pagePad)
        }
    }

    private var skeletonResults: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 76)
                    .padding(.horizontal, C.pagePad)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func resultSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(C.text)
                .padding(.horizontal, C.pagePad)
            content()
        }
    }

    private func channelsResults(_ channels: [SearchResultChannel]) -> some View {
        resultSection("Channels") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(channels) { ch in
                        Button {
                            openSearchItem(title: ch.name, subtitle: ch.handle.map { "@\($0)" }, type: "channel", route: .channel(ch.handle ?? ch.id))
                        } label: {
                            SearchChannelCard(channel: ch)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }

    private func showsResults(_ shows: [SearchResultShow]) -> some View {
        resultSection("Shows & Series") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shows) { show in
                        Button {
                            openSearchItem(title: show.title, subtitle: show.genre, type: "show", route: .show(show.id))
                        } label: {
                            ShowPortraitCard(show: show)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }

    private func episodesResults(_ episodes: [SearchResultEpisode]) -> some View {
        resultSection("Episodes") {
            LazyVStack(spacing: 0) {
                ForEach(episodes) { ep in
                    Button {
                        openSearchItem(title: ep.title, subtitle: ep.season?.show?.title, type: "episode", route: .episode(ep.id))
                    } label: {
                        EpisodeSearchRow(ep: ep)
                    }
                    .buttonStyle(.plain)
                    Divider().background(C.border).padding(.leading, C.pagePad + 112)
                }
            }
        }
    }

    private func videosResults(_ videos: [SearchResultVideo]) -> some View {
        resultSection("Videos") {
            LazyVStack(spacing: 0) {
                ForEach(videos) { video in
                    let isShort = video.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short"
                    let route: AppRoute = isShort
                        ? .short(video.id, showId: nil, channelId: video.channel?.id)
                        : .media(id: video.id, type: video.type, channelId: video.channel?.id)
                    Button {
                        if isShort { ShortNavigationCache.shared.seedIDs(searchVideoShortIDs(videos)) }
                        openSearchItem(title: video.title, subtitle: video.channel?.name, type: isShort ? "short" : "video", route: route)
                    } label: {
                        VideoSearchRow(video: video)
                    }
                    .buttonStyle(.plain)
                    Divider().background(C.border).padding(.leading, C.pagePad + 112)
                }
            }
        }
    }

    private func peopleResults(_ people: [SearchResultPerson]) -> some View {
        resultSection("People & Atmospheres") {
            LazyVStack(spacing: 0) {
                ForEach(people) { person in
                    Button {
                        guard let handle = person.handle else { return }
                        openSearchItem(
                            title: person.name ?? "@\(handle)",
                            subtitle: "@\(handle)",
                            type: "person",
                            route: .atmo(handle)
                        )
                    } label: {
                        SocialSearchRow(
                            imageUrl: person.image,
                            title: person.name ?? person.handle.map { "@\($0)" } ?? "Atmosphere",
                            subtitle: person.handle.map { "@\($0)" },
                            detail: person.bio,
                            symbol: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func vibesResults(_ vibes: [SearchResultVibe]) -> some View {
        resultSection("Community Vibes") {
            LazyVStack(spacing: 0) {
                ForEach(vibes) { vibe in
                    Button {
                        openSearchItem(
                            title: vibe.name,
                            subtitle: vibe.followerCount.map { "\($0) followers" },
                            type: "vibe",
                            route: .vibe(vibe.slug)
                        )
                    } label: {
                        SocialSearchRow(
                            imageUrl: vibe.avatarUrl,
                            title: vibe.name,
                            subtitle: vibe.followerCount.map { "\($0) followers" },
                            detail: vibe.description,
                            symbol: "person.3.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func ripplesResults(_ ripples: [SearchResultRipple]) -> some View {
        resultSection("Public Ripples") {
            LazyVStack(spacing: 0) {
                ForEach(ripples) { ripple in
                    Button {
                        openSearchItem(
                            title: ripple.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? ripple.body!
                                : "Ripple",
                            subtitle: ripple.club.name,
                            type: "ripple",
                            route: .ripple(ripple.id)
                        )
                    } label: {
                        SocialSearchRow(
                            imageUrl: ripple.imageUrl ?? ripple.author.image,
                            title: ripple.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? ripple.body!
                                : "\(ripple.author.name ?? ripple.author.handle ?? "A user") shared a Ripple",
                            subtitle: ripple.club.name,
                            detail: searchEngagementLine(energy: ripple.energyCount, comments: ripple.commentCount),
                            symbol: "wave.3.right"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func collectionsResults(_ collections: [SearchResultCollection]) -> some View {
        resultSection("Community Collections") {
            LazyVStack(spacing: 0) {
                ForEach(collections) { collection in
                    Button {
                        openSearchItem(
                            title: collection.title,
                            subtitle: collection.user?.name,
                            type: "collection",
                            route: .collection(collection.id)
                        )
                    } label: {
                        SocialSearchRow(
                            imageUrl: collection.user?.image,
                            title: collection.title,
                            subtitle: collection.user?.name,
                            detail: collection.count?.items.map { "\($0) items" },
                            symbol: "rectangle.stack.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.text)
            Button("Retry") { Task { await runFullSearch() } }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(C.watch)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("No results for \"\(committedQuery.isEmpty ? trimmedQuery : committedQuery)\"")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            Text("Try different keywords or browse the catalog.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
            HStack(spacing: 10) {
                Button("Browse Shows") {
                    NotificationCenter.default.post(name: .exploreSectionRequested, object: "shows")
                    dismiss()
                }
                Button("Browse Channels") {
                    NotificationCenter.default.post(name: .exploreSectionRequested, object: "channels")
                    dismiss()
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(C.watch)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, C.pagePad)
    }

    private var searchHistory: [SearchHistoryItem] {
        guard let data = searchHistoryData.data(using: .utf8),
              let items = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    private func addSearchHistory(_ item: SearchHistoryItem) {
        var items = searchHistory.filter { $0.id != item.id && $0.title.caseInsensitiveCompare(item.title) != .orderedSame }
        items.insert(item, at: 0)
        items = Array(items.prefix(10))
        if let data = try? JSONEncoder().encode(items), let value = String(data: data, encoding: .utf8) {
            searchHistoryData = value
        }
        Task { try? await APIClient.shared.saveSearchHistory(query: item.title) }
    }

    private func removeSearchHistory(_ item: SearchHistoryItem) {
        let items = searchHistory.filter { $0.id != item.id }
        if let data = try? JSONEncoder().encode(items), let value = String(data: data, encoding: .utf8) {
            searchHistoryData = value
        }
        Task { try? await APIClient.shared.removeSearchHistory(query: item.title) }
    }

    private func clearSearchHistory() {
        searchHistoryData = "[]"
        Task { try? await APIClient.shared.clearSearchHistoryRemote() }
    }

    private func loadRemoteSearchHistoryIfNeeded() async {
        guard SessionStorage.token != nil else { return }
        guard let remote = try? await APIClient.shared.fetchSearchHistory(), !remote.isEmpty else { return }
        let existing = searchHistory
        var items = existing
        for query in remote.reversed() where !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = queryHistoryItem(query)
            items.removeAll { $0.title.caseInsensitiveCompare(query) == .orderedSame }
            items.insert(item, at: 0)
        }
        items = Array(items.prefix(10))
        if let data = try? JSONEncoder().encode(items), let value = String(data: data, encoding: .utf8) {
            searchHistoryData = value
        }
    }

    private func handleQueryChange(oldValue: String, newValue: String) {
        debounceTask?.cancel()
        suggestGeneration &+= 1
        searchGeneration &+= 1
        showResults = false
        searchError = nil
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggests = []
            selectedSuggestionID = nil
            isLoadingSuggest = false
            Task { await loadTrendingIfNeeded() }
            return
        }
        selectedSuggestionID = nil
        isLoadingSuggest = true
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await runSuggest(q: trimmed)
        }
    }

    private func runSuggest(q: String) async {
        suggestGeneration &+= 1
        let generation = suggestGeneration
        do {
            let refreshedSuggestions = try await APIClient.shared.searchSuggest(q: q)
            guard generation == suggestGeneration, trimmedQuery == q else { return }
            suggests = refreshedSuggestions
            selectedSuggestionID = visibleSuggestionItems.first?.id
            isOffline = false
        } catch {
            guard generation == suggestGeneration, trimmedQuery == q else { return }
            suggests = []
            selectedSuggestionID = nil
            if (error as? URLError)?.code == .notConnectedToInternet { isOffline = true }
        }
        isLoadingSuggest = false
    }

    private func loadTrendingIfNeeded() async {
        guard trending.isEmpty else { return }
        trendingGeneration &+= 1
        let generation = trendingGeneration
        do {
            let refreshedTrending = try await APIClient.shared.searchTrendingSuggest()
            guard generation == trendingGeneration else { return }
            trending = refreshedTrending
            if trimmedQuery.isEmpty, selectedSuggestionID == nil {
                selectedSuggestionID = visibleSuggestionItems.first?.id
            }
            isOffline = false
        } catch {
            guard generation == trendingGeneration else { return }
            trending = []
            selectedSuggestionID = nil
            if (error as? URLError)?.code == .notConnectedToInternet { isOffline = true }
        }
    }

    private func submitSearchAnyway() {
        guard trimmedQuery.count >= 2 else { return }
        Task { await runFullSearch() }
    }

    private func submitActiveSuggestionOrSearch() {
        if !showResults,
           let selectedSuggestionID,
           let item = visibleSuggestionItems.first(where: { $0.id == selectedSuggestionID }) {
            activateSuggestion(item)
            return
        }
        submitSearchAnyway()
    }

    private func moveSuggestionSelection(by delta: Int) {
        let items = visibleSuggestionItems
        guard !items.isEmpty else {
            selectedSuggestionID = nil
            return
        }
        let currentIndex = selectedSuggestionID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        } else {
            nextIndex = delta >= 0 ? 0 : items.count - 1
        }
        selectedSuggestionID = items[nextIndex].id
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                isOffline = path.status != .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "westreem.search.network-monitor"))
        networkMonitor = monitor
    }

    private func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    private func runFullSearch() async {
        let trimmed = trimmedQuery
        guard trimmed.count >= 2 else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        let requestedFilter = activeFilter
        isLoadingResults = true
        showResults = true
        suggests = []
        committedQuery = trimmed
        searchError = nil
        do {
            let refreshedResults = try await APIClient.shared.search(q: trimmed, type: requestedFilter.rawValue)
            guard generation == searchGeneration,
                  trimmedQuery == trimmed,
                  activeFilter == requestedFilter else { return }
            results = refreshedResults
            isOffline = false
            UIAccessibility.post(notification: .announcement, argument: "\(results.totalCount) results for \(trimmed)")
            addSearchHistory(queryHistoryItem(trimmed))
        } catch {
            guard generation == searchGeneration,
                  trimmedQuery == trimmed,
                  activeFilter == requestedFilter else { return }
            results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
            searchError = "Something went wrong"
            if (error as? URLError)?.code == .notConnectedToInternet { isOffline = true }
        }
        isLoadingResults = false
    }

    private func activateSuggestion(_ item: SuggestItem) {
        query = item.title
        if let route = AppRoute.route(link: item.href, notificationType: item.type) ?? route(for: item.href, type: item.type) {
            openSearchItem(title: item.title, subtitle: item.meta, type: item.type, route: route)
            return
        }
        Task { await runFullSearch() }
    }

    private func openSearchItem(title: String, subtitle: String?, type: String, route: AppRoute) {
        let item = historyItem(title: title, subtitle: subtitle, type: type, route: route)
        addSearchHistory(item)
        suggestionRoute = route
    }

    private func openHistoryItem(_ item: SearchHistoryItem) {
        query = item.title
        if let route = item.route {
            addSearchHistory(item)
            suggestionRoute = route
        } else {
            Task { await runFullSearch() }
        }
    }

    private func searchVideoShortIDs(_ videos: [SearchResultVideo]) -> [String] {
        videos.compactMap { video in
            guard video.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short" else { return nil }
            return video.id
        }
    }

    private func historyItem(title: String, subtitle: String?, type: String, route: AppRoute) -> SearchHistoryItem {
        let normalizedType: String
        let targetId: String
        let showId: String?
        let channelId: String?

        switch route {
        case .video(let id):
            normalizedType = "video"; targetId = id; showId = nil; channelId = nil
        case .short(let id, let routeShowId, let routeChannelId):
            normalizedType = "short"; targetId = id; showId = routeShowId; channelId = routeChannelId
        case .episode(let id):
            normalizedType = "episode"; targetId = id; showId = nil; channelId = nil
        case .channel(let id):
            normalizedType = "channel"; targetId = id; showId = nil; channelId = nil
        case .show(let id):
            normalizedType = "show"; targetId = id; showId = nil; channelId = nil
        case .showSeason(let routeShowId, _):
            normalizedType = "show"; targetId = routeShowId; showId = nil; channelId = nil
        case .atmo(let handle):
            normalizedType = "person"; targetId = handle; showId = nil; channelId = nil
        case .vibe(let slug):
            normalizedType = "vibe"; targetId = slug; showId = nil; channelId = nil
        case .ripple(let id):
            normalizedType = "ripple"; targetId = id; showId = nil; channelId = nil
        case .collection(let id):
            normalizedType = "collection"; targetId = id; showId = nil; channelId = nil
        default:
            normalizedType = type; targetId = route.id; showId = nil; channelId = nil
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

    private func queryHistoryItem(_ query: String) -> SearchHistoryItem {
        SearchHistoryItem(id: "query-\(query.lowercased())", title: query, subtitle: nil, type: "query", targetId: query, showId: nil, channelId: nil)
    }

    private func suggestionSections(items: [SuggestItem]) -> [SuggestionSection] {
        let ordered: [(String, String, (SuggestItem) -> Bool)] = [
            ("channels", "Channels", { $0.type.lowercased() == "channel" }),
            ("shows", "Shows", { $0.type.lowercased() == "show" }),
            ("people", "People & Atmospheres", { $0.type.lowercased() == "person" }),
            ("vibes", "Community Vibes", { $0.type.lowercased() == "vibe" }),
            ("ripples", "Public Ripples", { $0.type.lowercased() == "ripple" }),
            ("collections", "Community Collections", { $0.type.lowercased() == "collection" }),
            ("videos", "Videos & Shorts", { ["video", "short"].contains($0.type.lowercased()) }),
            ("episodes", "Episodes", { $0.type.lowercased() == "episode" })
        ]
        return ordered.compactMap { id, title, matches in
            let sectionItems = items.filter(matches)
            return sectionItems.isEmpty ? nil : SuggestionSection(id: id, title: title, items: sectionItems)
        }
    }

    private func route(for href: String, type: String) -> AppRoute? {
        let path: String
        if let url = URL(string: href), let host = url.host, !host.isEmpty {
            path = url.path
        } else {
            path = href
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" { return .episode(parts[2]) }
        if parts.count >= 2, parts[0] == "watch" { return type == "short" ? .short(parts[1], showId: nil, channelId: nil) : .video(parts[1]) }
        if parts.count >= 2, parts[0] == "shows" { return .show(parts[1]) }
        if parts.count >= 2, parts[0] == "channel" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "channels" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "atmo" { return .atmo(parts[1]) }
        if parts.count >= 4, parts[0] == "vibes", parts[2] == "posts" { return .ripple(parts[3]) }
        if parts.count >= 2, parts[0] == "vibes" { return .vibe(parts[1]) }
        if parts.count >= 2, parts[0] == "collections" { return .collection(parts[1]) }
        return nil
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id): VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId, showsDismissControls: true)
        case .episode(let id): EpisodeWatchView(episodeId: id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .showSeason(let showId, let seasonId): ShowView(showId: showId, initialSeasonId: seasonId)
        case .showAccess(let showId, let productId, let intent, let handoffId):
            ShowView(showId: showId, handoffProductId: productId, handoffIntent: intent, handoffPublicId: handoffId)
        case .handoff(let id): HandoffResolverView(publicId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        case .vibe(let slug): VibeDetailView(slug: slug)
        case .vibeManagement(let slug, let tab): VibeDetailView(slug: slug, initialManagementTab: tab)
        case .vibeInvite(let token): VibeInviteAcceptView(token: token)
        case .event(let slug): VibeEventDetailView(slug: slug)
        case .eventInvite(let token): VibeEventInviteView(token: token)
        case .ripple(let postId): RippleDetailView(postId: postId)
        case .atmo(let handle): AtmoProfileView(handle: handle)
        case .search(let query): SearchView(initialQuery: query)
        }
    }

    private func badgeLabel(for type: String) -> String {
        switch type.lowercased() {
        case "video": return "Video"
        case "short": return "Short"
        case "show": return "Show"
        case "episode": return "Episode"
        case "channel": return "Channel"
        case "person": return "Atmosphere"
        case "vibe": return "Vibe"
        case "ripple": return "Ripple"
        case "collection": return "Collection"
        default: return "Result"
        }
    }

    private func badgeColor(for type: String) -> Color {
        switch type.lowercased() {
        case "video": return Color(hex: "#60A5FA")
        case "short": return Color(hex: "#F472B6")
        case "show": return Color(hex: "#A78BFA")
        case "episode": return Color(hex: "#34D399")
        case "channel": return Color(hex: "#FBBF24")
        case "person": return Color(hex: "#22D3EE")
        case "vibe": return Color(hex: "#C084FC")
        case "ripple": return Color(hex: "#6AE383")
        case "collection": return Color(hex: "#FB923C")
        default: return C.watch
        }
    }
}

private struct SocialSearchRow: View {
    let imageUrl: String?
    let title: String
    let subtitle: String?
    let detail: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            CachedRemoteImage(
                url: C.mediaURL(imageUrl),
                targetSize: CGSize(width: 52, height: 52)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.06))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(C.textTertiary)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private func searchEngagementLine(energy: Int?, comments: Int?) -> String? {
    var parts = [String]()
    if let energy, energy > 0 { parts.append("\(energy) Energy") }
    if let comments, comments > 0 { parts.append("\(comments) Comments") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private struct SearchChannelCard: View {
    let channel: SearchResultChannel

    var body: some View {
        VStack(spacing: 7) {
            CachedRemoteImage(
                url: C.mediaURL(channel.avatarUrl),
                targetSize: CGSize(width: 62, height: 62)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.white.opacity(0.07))
            }
            .frame(width: 62, height: 62, alignment: focusAlignment(channel.avatarFocus))
            .clipShape(Circle())
            .clipped()

            HStack(spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                if channel.verified == true {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(C.watch)
                }
            }
            .frame(width: 112)

            Text(channel.handle.map { "@\($0)" } ?? formatFollowers(channel.followerCount))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(C.textMuted)
                .lineLimit(1)
                .frame(width: 112)
        }
        .frame(width: 112)
    }
}

private struct ShowPortraitCard: View {
    let show: SearchResultShow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedRemoteImage(
                url: C.mediaURL(show.coverUrl),
                targetSize: CGSize(width: 116, height: 174)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 116, height: 174, alignment: focusAlignment(show.coverFocus))
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(show.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 116, alignment: .leading)

            Text(showSubtitle(show))
                .font(.caption2)
                .foregroundStyle(C.textMuted)
                .lineLimit(1)
                .frame(width: 116, alignment: .leading)
        }
        .frame(width: 116)
    }
}

private struct EpisodeSearchRow: View {
    let ep: SearchResultEpisode

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(url: ep.thumbnailUrl, type: "episode", focus: ep.thumbnailFocus)

            VStack(alignment: .leading, spacing: 4) {
                if let sNum = ep.season?.seasonNumber, let eNum = ep.episodeNumber {
                    Text("S\(sNum) E\(eNum)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(C.watch)
                }
                Text(ep.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let showTitle = ep.season?.show?.title {
                    Text(showTitle)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
                SearchMetaLine(duration: ep.duration, views: ep.views)
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
    }
}

private struct VideoSearchRow: View {
    let video: SearchResultVideo

    var body: some View {
        HStack(spacing: 12) {
            SearchThumbnail(url: video.thumbnailUrl, type: video.type, focus: video.thumbnailFocus)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let channel = video.channel {
                    Text(channel.name)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
                SearchMetaLine(duration: video.duration, views: video.views)
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
    }
}

private struct SearchThumbnail: View {
    let url: String?
    let type: String?
    let focus: String?

    var body: some View {
        CachedRemoteImage(
            url: C.mediaURL(url),
            targetSize: CGSize(width: 104, height: 104 / C.mediaAspectRatio(forContentType: type))
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.06)
        }
        .frame(width: 104, height: 104 / C.mediaAspectRatio(forContentType: type), alignment: focusAlignment(focus))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .clipped()
    }
}

private struct SearchMetaLine: View {
    let duration: Double?
    let views: Int?

    var body: some View {
        let parts = [duration.map(formatDuration), views.map(formatViews)].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(C.textTertiary)
                .lineLimit(1)
        }
    }
}

private func suggestionAspectRatio(for type: String) -> CGFloat {
    switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "show": return C.mediaAspectRatio(forContentType: "show")
    case "channel": return 1
    default: return 16 / 9
    }
}

private func focusAlignment(_ focus: String?) -> Alignment {
    guard let focus else { return .center }
    let values = focus
        .split(whereSeparator: { $0 == " " || $0 == "," })
        .compactMap { Double($0) }
    guard values.count >= 2 else { return .center }

    let horizontal: HorizontalAlignment
    switch values[0] {
    case ..<0.33: horizontal = .leading
    case 0.67...: horizontal = .trailing
    default: horizontal = .center
    }

    let vertical: VerticalAlignment
    switch values[1] {
    case ..<0.33: vertical = .top
    case 0.67...: vertical = .bottom
    default: vertical = .center
    }

    return Alignment(horizontal: horizontal, vertical: vertical)
}

private func showSubtitle(_ show: SearchResultShow) -> String {
    var parts = [String]()
    if let year = show.productionYear, !year.isEmpty { parts.append(year) }
    if let seasons = show.seasonCount {
        parts.append("\(seasons) Season\(seasons == 1 ? "" : "s")")
    } else if let genre = show.genre, !genre.isEmpty {
        parts.append(genre)
    }
    return parts.joined(separator: " · ")
}

private func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))" }
    return "\(minutes):\(String(format: "%02d", secs))"
}

private func formatViews(_ views: Int) -> String {
    if views >= 1_000_000 { return String(format: "%.1fM views", Double(views) / 1_000_000) }
    if views >= 1_000 { return String(format: "%.1fK views", Double(views) / 1_000) }
    return "\(views) views"
}

private func formatFollowers(_ followers: Int?) -> String {
    guard let followers else { return "Channel" }
    if followers >= 1_000_000 { return String(format: "%.1fM followers", Double(followers) / 1_000_000) }
    if followers >= 1_000 { return String(format: "%.1fK followers", Double(followers) / 1_000) }
    return "\(followers) followers"
}
