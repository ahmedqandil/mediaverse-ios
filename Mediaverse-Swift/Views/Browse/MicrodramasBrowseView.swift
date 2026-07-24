import SwiftUI

/// Microdrama discovery surface.
/// Mirrors web /microdramas: header, hero, trending/new rows, genre rows, and 9:16 cards.
struct MicrodramasBrowseView: View {

    let isBrowseActive: Bool

    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @State private var selectedSectionID: String? = nil
    @State private var curationSections = [PageSection]()
    @State private var trending = [MicrodramaListShow]()
    @State private var newRels = [MicrodramaListShow]()
    @State private var curationListings = [AssembledListing]()
    @State private var continueItems = [ProgressItem]()
    @State private var isLoading = true
    @State private var loadGeneration = 0
    init(isBrowseActive: Bool = true) {
        self.isBrowseActive = isBrowseActive
    }
    private var pageConfig: PlatformBrowseItem { platformConfig.browseItem(id: "microdramas") }

    private var hero: MicrodramaListShow? { trending.first ?? newRels.first }
    private var allMicrodramas: [MicrodramaListShow] {
        var seen = Set<String>()
        return (trending + newRels).filter { seen.insert($0.id).inserted }
    }
    private var continueWatchingItems: [ProgressItem] {
        let showIds = Set(allMicrodramas.map(\.id))
        return continueItems.filter { item in
            guard let show = item.episode?.season?.show,
                  showIds.contains(show.id) else {
                return false
            }
            let type = C.normalizedContentType(show.showType)
            return type == "microdrama" || type == "micro-drama" || type == "microdramas" || type == "micro-dramas"
        }
    }
    private var curationHeroListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType == "hero" }
    }

    private var curationContentListings: [AssembledListing] {
        curationListings.filter { $0.normalizedTemplateType != "hero" }
    }

    private var genreMap: [(String, [MicrodramaListShow])] {
        var map = [String: [MicrodramaListShow]]()
        var seenByGenre = [String: Set<String>]()

        for show in trending + newRels {
            guard let genre = show.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty else { continue }
            var seen = seenByGenre[genre, default: []]
            guard !seen.contains(show.id) else { continue }
            seen.insert(show.id)
            seenByGenre[genre] = seen
            map[genre, default: []].append(show)
        }

        return map
            .filter { $0.value.count >= 2 }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !pageConfig.enabled {
                PlatformSectionUnavailableView(item: pageConfig)
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: C.sectionSpacing) {
                    if isLoading {
                        loadingContent
                    } else if trending.isEmpty && newRels.isEmpty && curationListings.isEmpty {
                        emptyState
                    } else {
                        if !curationListings.isEmpty {
                            ForEach(curationHeroListings) { listing in
                                NativeCurationListingView(listing: listing)
                            }

                            if !curationSections.isEmpty {
                                sectionTabs
                            }

                            ForEach(curationContentListings) { listing in
                                NativeCurationListingView(listing: listing)
                            }
                            if !continueWatchingItems.isEmpty {
                                ProgressExploreCarousel(items: continueWatchingItems, kind: .microdramas)
                            }
                        } else {
                            if let hero {
                                MicrodramaHero(show: hero)
                            }
                            if !continueWatchingItems.isEmpty {
                                ProgressExploreCarousel(items: continueWatchingItems, kind: .microdramas)
                            }
                            MicrodramaCarousel(title: "Trending", shows: trending, showsIcon: "flame.fill")
                            MicrodramaCarousel(title: "New Releases", shows: newRels, showsIcon: "sparkles")
                            ForEach(genreMap, id: \.0) { genre, shows in
                                MicrodramaCarousel(title: genre, shows: shows, showsIcon: nil)
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

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(curationSections) { section in
                    GenrePill(label: section.name, selected: selectedSectionID == section.id) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSectionID = section.id
                        }
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.top, 12)
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            RoundedRectangle(cornerRadius: C.cardRadius)
                .fill(Color.white.opacity(0.05))
                .frame(height: 256)
                .padding(.horizontal, C.pagePad)
                .shimmering()

            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 128, height: 16)
                        .padding(.horizontal, C.pagePad)
                        .shimmering()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: C.cardRadius)
                                    .fill(Color.white.opacity(0.05))
                                    .frame(width: CarouselCardMetrics.posterWidth)
                                    .aspectRatio(C.mediaAspectRatio(forContentType: "microdrama"), contentMode: .fit)
                                    .shimmering()
                            }
                        }
                        .padding(.horizontal, C.pagePad)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 48))
                .foregroundStyle(Color.white.opacity(0.22))
            Text("No microdramas yet")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Check back soon - new series are being added.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, minHeight: 340)
    }

    @MainActor
    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if let cachedPage = CurationManager.shared.cachedPage(key: "microdramas", section: selectedSectionID, allowExpired: true), cachedPage.hasCurationSurface {
            applyCurationPage(cachedPage)
            isLoading = false
        } else {
            isLoading = trending.isEmpty && newRels.isEmpty && curationListings.isEmpty
        }

        async let c = APIClient.shared.fetchContinueWatching()

        let refreshedPage = try? await CurationManager.shared.fetchPage(key: "microdramas", section: selectedSectionID)
        guard generation == loadGeneration else { return }
        if let page = refreshedPage, page.hasCurationSurface {
            applyCurationPage(page)
        } else if trending.isEmpty && newRels.isEmpty {
            curationSections = []
            selectedSectionID = nil
            curationListings = []
            async let t = APIClient.shared.fetchMicrodramas(section: "trending", limit: 20)
            async let n = APIClient.shared.fetchMicrodramas(section: "new", limit: 20)
            let (tr, nr) = (try? await t, try? await n)
            guard generation == loadGeneration else { return }
            trending = tr ?? []
            newRels = nr ?? []
        }

        let refreshedContinueItems = (try? await c)?.items
        guard generation == loadGeneration else { return }
        continueItems = refreshedContinueItems ?? continueItems
        isLoading = false
    }

    @MainActor
    private func applyCurationPage(_ page: AssembledPage) {
        let sections = page.sortedSections
        curationSections = sections
        if let selectedSectionID,
           !sections.contains(where: { $0.id == selectedSectionID }) {
            self.selectedSectionID = sections.first?.id
        } else if selectedSectionID == nil {
            selectedSectionID = sections.first?.id
        }
        curationListings = page.listings(forSectionID: selectedSectionID)
        let sourceItems = curationListings.isEmpty ? page.curationItems : curationListings.flatMap(\.items)
        let microdramas = sourceItems
            .filter { item in
                let type = item.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return type == "show" || type == "microdrama"
            }
            .map(\.asMicrodramaListShow)
            .uniqueByID()
        trending = microdramas
        newRels = []
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

private struct MicrodramaHero: View {
    let show: MicrodramaListShow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                heroImage
                    .frame(maxWidth: .infinity)
                    .frame(height: C.heroHeight)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.42), .black.opacity(0.96)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label("Microdrama", systemImage: "iphone")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())

                    if let genre = show.genre {
                        Text(genre)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                Text(show.title)
                    .font(.title2.bold())
                    .foregroundStyle(C.text)
                    .lineLimit(2)

                if let description = show.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    NavigationLink(value: AppRoute.microdramaWatch(show.id)) {
                        Label("Watch Now", systemImage: "play.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: AppRoute.microdramaShow(show.id)) {
                        Text("More Info")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.top, 12)
            .padding(.bottom, C.pagePad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct MicrodramaCarousel: View {
    let title: String
    let shows: [MicrodramaListShow]
    let showsIcon: String?

    var body: some View {
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    if let showsIcon {
                        Image(systemName: showsIcon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(C.watch)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(C.text)
                }
                .padding(.horizontal, C.pagePad)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CarouselCardMetrics.spacing) {
                        ForEach(shows) { show in
                            NavigationLink(value: AppRoute.microdramaShow(show.id)) {
                                MicrodramaCard(show: show)
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

private struct MicrodramaCard: View {
    let show: MicrodramaListShow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                posterImage
                    .frame(width: CarouselCardMetrics.posterWidth)
                    .aspectRatio(C.mediaAspectRatio(forContentType: "microdrama"), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
                .opacity(show.seasonCount > 0 ? 1 : 0)

                if show.seasonCount > 0 {
                    Text("\(show.seasonCount) \(show.seasonCount == 1 ? "season" : "seasons")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.58))
                        .clipShape(Capsule())
                        .padding(7)
                }
            }
            .frame(width: CarouselCardMetrics.posterWidth)
            .aspectRatio(C.mediaAspectRatio(forContentType: "microdrama"), contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .frame(width: CarouselCardMetrics.posterWidth, alignment: .leading)

                if let genre = show.genre {
                    Text(genre)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                        .frame(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.metaHeight, alignment: .leading)
                } else {
                    Color.clear.frame(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.metaHeight)
                }
            }
            .frame(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.textBlockHeight, alignment: .topLeading)
        }
        .frame(width: CarouselCardMetrics.posterWidth, alignment: .leading)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let imageURL = C.mediaURL(show.coverUrl ?? show.bannerUrl) {
            CachedRemoteImage(url: imageURL, targetSize: CGSize(width: CarouselCardMetrics.posterWidth, height: CarouselCardMetrics.height(width: CarouselCardMetrics.posterWidth, contentType: "microdrama"))) { image in
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
            LinearGradient(
                colors: [Color(hex: "#4C1D95").opacity(0.42), Color(hex: "#1E1B4B").opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "iphone")
                .font(.system(size: 32))
                .foregroundStyle(Color.white.opacity(0.32))
        }
    }
}
