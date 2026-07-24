import SwiftUI

/// TV Shows browse page.
/// Mirrors the mobile web /shows route: hero, search mode, New & Popular, and genre rows.
struct ShowsBrowseView: View {

    let isBrowseActive: Bool

    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @State private var allShows = [ShowBrowseCard]()
    @State private var searchResults = [ShowBrowseCard]()
    @State private var query = ""
    @State private var selectedGenre = "All"
    @State private var selectedSectionID: String? = nil
    @State private var curationSections = [PageSection]()
    @State private var curationListings = [AssembledListing]()
    @State private var isSearching = false
    @State private var isLoading = true
    @State private var isSearchLoading = false
    @State private var continueItems = [ProgressItem]()
    @State private var loadGeneration = 0
    @State private var searchGeneration = 0

    init(isBrowseActive: Bool = true) {
        self.isBrowseActive = isBrowseActive
    }

    private var showGenres: [String] {
        if !curationSections.isEmpty {
            return curationSections
                .sorted { $0.order < $1.order }
                .map(\.name)
        }
        let genres = Set(
            allShows.compactMap { show in
                show.genre?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        )
        return ["All"] + genres.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredShows: [ShowBrowseCard] {
        guard curationSections.isEmpty else { return allShows }
        guard selectedGenre != "All" else { return allShows }
        return allShows.filter { show in
            show.genre?.localizedCaseInsensitiveCompare(selectedGenre) == .orderedSame
        }
    }

    private var hero: ShowBrowseCard? { filteredShows.first }
    private var newAndPopular: [ShowBrowseCard] { Array(filteredShows.prefix(16)) }
    private var pageConfig: PlatformBrowseItem { platformConfig.browseItem(id: "shows") }
    private var continueWatchingItems: [ProgressItem] {
        let visibleShowIds = Set(filteredShows.map(\.id))
        return continueItems.filter { item in
            guard let show = item.episode?.season?.show,
                  visibleShowIds.contains(show.id),
                  !show.isMovie,
                  C.normalizedContentType(show.showType) != "microdrama",
                  C.normalizedContentType(show.showType) != "micro-drama" else {
                return false
            }
            return true
        }
    }
    private var curationHeroListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType == "hero" }
    }

    private var curationContentListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType != "hero" }
    }

    private var genreRows: [(String, [ShowBrowseCard])] {
        guard selectedGenre == "All" else { return [] }
        var grouped = [String: [ShowBrowseCard]]()
        for show in filteredShows {
            guard let genre = show.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty else { continue }
            grouped[genre, default: []].append(show)
        }
        return grouped
            .filter { $0.value.count >= 2 }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, Array($0.value.prefix(12))) }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if !pageConfig.enabled {
                PlatformSectionUnavailableView(item: pageConfig)
            } else if isLoading {
                loadingState
            } else if allShows.isEmpty && curationListings.isEmpty {
                emptyState(title: "No shows yet", subtitle: "Shows will appear here once published.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: C.sectionSpacing) {
                        if !curationListings.isEmpty, !isSearching {
                            ForEach(curationHeroListings) { listing in
                                NativeCurationListingView(listing: listing)
                            }
                        } else if let hero, !isSearching {
                            ShowsHeroCard(show: hero)
                        }

                        headerAndSearch

                        if isSearching {
                            searchSection
                        } else {
                            if !continueWatchingItems.isEmpty, curationListings.isEmpty {
                                ProgressExploreCarousel(items: continueWatchingItems, kind: .shows)
                            }

                            if !curationListings.isEmpty {
                                ForEach(curationContentListings) { listing in
                                    NativeCurationListingView(listing: listing)
                                }
                            } else {
                                ShowsCarousel(title: selectedGenre == "All" ? "New & Popular" : selectedGenre, shows: newAndPopular, seeAllGenre: nil)

                                ForEach(genreRows, id: \.0) { genre, shows in
                                    ShowsCarousel(title: genre, shows: shows, seeAllGenre: genre)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
                .refreshable {
                    C.lightHaptic()
                    await load()
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard isBrowseActive else { return }
            guard pageConfig.enabled else {
                isLoading = false
                return
            }
            await load()
        }
        .onChange(of: isBrowseActive) { _, isActive in
            guard isActive, isLoading else { return }
            Task { await load() }
        }
    }

    private var headerAndSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            if curationListings.isEmpty || !curationSections.isEmpty {
                genreSubtabs
            }

            if curationListings.isEmpty {
                HStack(spacing: 10) {
                TextField("Search shows...", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .font(.subheadline)
                    .foregroundStyle(C.text)
                    .onSubmit { Task { await submitSearch() } }
                    .onChange(of: query) { _, newValue in
                        searchGeneration &+= 1
                        isSearchLoading = false
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            isSearching = false
                            searchResults = []
                        }
                    }

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                } else {
                    Button {
                        query = ""
                        isSearching = false
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(C.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.white.opacity(0.08))
            .overlay {
                Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
            .clipShape(Capsule())
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var genreSubtabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(showGenres, id: \.self) { genre in
                    GenrePill(label: genre, selected: selectedGenre == genre) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGenre = genre
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                isSearching = false
                                searchResults = []
                            }
                        }
                        if let section = curationSections.first(where: { $0.name == genre }) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedSectionID = section.id
                            }
                            Task { await load() }
                        }
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .frame(height: 32)
        .padding(.top, 12)
        .padding(.horizontal, -C.pagePad)
    }

    private var searchSection: some View {
        Group {
            if isSearchLoading {
                searchLoadingGrid
            } else if searchResults.isEmpty {
                emptyState(title: "No shows found for \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"", subtitle: "Try a different keyword or browse below")
                    .frame(minHeight: 240)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 16
                ) {
                    ForEach(searchResults) { show in
                        NavigationLink(value: AppRoute.show(show.id)) {
                            ShowPosterCard(show: show)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.white.opacity(0.05))
                    .aspectRatio(C.mediaAspectRatio(forContentType: "video"), contentMode: .fit)
                    .shimmering()
                searchLoadingGrid
            }
            .padding(.top, 1)
        }
    }

    private var searchLoadingGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 16
        ) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: C.cardRadius)
                    .fill(Color.white.opacity(0.06))
                    .aspectRatio(C.mediaAspectRatio(forContentType: "show"), contentMode: .fit)
                    .shimmering()
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 42))
                .foregroundStyle(Color.white.opacity(0.2))
            Text(title)
                .font(.headline)
                .foregroundStyle(C.text)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if let cachedPage = CurationManager.shared.cachedPage(key: "shows", section: selectedSectionID, allowExpired: true), cachedPage.hasCurationSurface {
            applyCurationPage(cachedPage)
            isLoading = false
        } else {
            isLoading = allShows.isEmpty && curationListings.isEmpty
        }

        do {
            async let pageTask = CurationManager.shared.fetchPage(key: "shows", section: selectedSectionID)
            async let continueTask = APIClient.shared.fetchContinueWatching()
            let page = try await pageTask
            guard generation == loadGeneration else { return }
            applyCurationPage(page)
            let refreshedContinueItems = (try? await continueTask)?.items ?? []
            guard generation == loadGeneration else { return }
            continueItems = refreshedContinueItems
        } catch {
            guard generation == loadGeneration else { return }
            if allShows.isEmpty && curationListings.isEmpty {
                continueItems = []
                curationSections = []
                curationListings = []
                selectedSectionID = nil
            }
        }
        isLoading = false
    }

    @MainActor
    private func applyCurationPage(_ page: AssembledPage) {
        let sections = page.sortedSections
        curationSections = sections
        if let selectedSectionID,
           let selectedSection = sections.first(where: { $0.id == selectedSectionID }) {
            selectedGenre = selectedSection.name
        } else if let firstSection = sections.first {
            selectedSectionID = firstSection.id
            selectedGenre = firstSection.name
        } else if selectedSectionID != nil {
            selectedSectionID = nil
            selectedGenre = "All"
        }
        curationListings = page.listings(forSectionID: selectedSectionID)
        let sourceItems = curationListings.isEmpty ? page.curationItems : curationListings.flatMap(\.items)
        allShows = sourceItems
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "show" }
            .map(\.asShowBrowseCard)
            .uniqueByID()
    }

    @MainActor
    private func submitSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }

        isSearching = true
        isSearchLoading = true
        searchGeneration &+= 1
        let generation = searchGeneration
        do {
            let refreshedResults = try await APIClient.shared.fetchShowsBrowse(q: trimmed)
            guard generation == searchGeneration,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            searchResults = refreshedResults
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
        }
        isSearchLoading = false
        isSearchLoading = false
    }
}

private struct ShowsHeroCard: View {
    let show: ShowBrowseCard

    var body: some View {
        NavigationLink(value: AppRoute.show(show.id)) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    heroImage
                        .frame(maxWidth: .infinity)
                        .frame(height: C.heroHeight)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0.05), .black.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Featured Series")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(C.watch)

                    Text(show.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let genre = show.genre { Text(genre) }
                        if show.genre != nil, let language = show.language { Text("."); Text(language.uppercased()) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)

                    if let description = show.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(2)
                    }

                    HStack(spacing: 10) {
                        Label("Watch Now", systemImage: "play.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(C.watch)
                            .clipShape(Capsule())

                        Text("More Info")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.top, 12)
                .padding(.bottom, C.pagePad)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let imageURL = C.mediaURL(show.bannerUrl ?? show.coverUrl) {
            CachedRemoteImage(url: imageURL, targetSize: CGSize(width: UIScreen.main.bounds.width, height: C.heroHeight)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        LinearGradient(
            colors: [C.watch.opacity(0.16), C.bg],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct ShowsCarousel: View {
    let title: String
    let shows: [ShowBrowseCard]
    let seeAllGenre: String?

    private var uniqueShows: [ShowBrowseCard] {
        shows.uniqueByID()
    }

    var body: some View {
        if !uniqueShows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(C.text)
                    Spacer()
                    if seeAllGenre != nil {
                        Text("See all")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                .padding(.horizontal, C.pagePad)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CarouselCardMetrics.spacing) {
                        ForEach(uniqueShows) { show in
                            NavigationLink(value: AppRoute.show(show.id)) {
                                ShowPosterCard(show: show)
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

private extension Array where Element: Identifiable, Element.ID == String {
    func uniqueByID() -> [Element] {
        var seen = Set<String>()
        return filter { item in
            seen.insert(item.id).inserted
        }
    }
}

struct ShowPosterCard: View {
    let show: ShowBrowseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                posterImage
                    .frame(width: CarouselCardMetrics.posterWidth)
                    .aspectRatio(C.mediaAspectRatio(forContentType: "show"), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
                    .clipped()

                if let rating = show.contentRating, !rating.isEmpty {
                    Text(rating.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(7)
                }

                EntitlementBadgeView(type: show.entitlementType ?? "")
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .frame(width: CarouselCardMetrics.posterWidth, alignment: .leading)

                HStack(spacing: 4) {
                    if let year = show.productionYear { Text(year) }
                    if show.productionYear != nil, show.seasonCount > 0 { Text(".") }
                    if show.seasonCount > 0 { Text("\(show.seasonCount) \(show.seasonCount == 1 ? "season" : "seasons")") }
                }
                .font(.caption2)
                .foregroundStyle(C.textMuted)
                .lineLimit(1)
                .frame(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
            }
            .frame(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: CarouselCardMetrics.posterWidth, alignment: .leading)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let imageURL = C.mediaURL(show.coverUrl) {
            CachedRemoteImage(url: imageURL, targetSize: CGSize(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.height(width: CarouselCardMetrics.posterWidth, contentType: "show"))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackPoster
            }
        } else {
            fallbackPoster
        }
    }

    private var fallbackPoster: some View {
        ZStack {
            C.elevated
            Image(systemName: "tv")
                .font(.system(size: 26))
                .foregroundStyle(Color.white.opacity(0.2))
        }
    }
}

struct GenrePill: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black : C.text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 14)
                .frame(minWidth: C.tabPillMinWidth)
                .frame(height: C.tabPillHeight)
                .background(selected ? C.watch : Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

extension View {
    func shimmering() -> some View {
        self.opacity(0.6)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: UUID())
    }
}
