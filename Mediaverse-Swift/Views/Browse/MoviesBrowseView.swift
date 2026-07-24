import SwiftUI

/// Movies browse page.
/// Mirrors the mobile web /movies route: Watch eyebrow, genre pills, and dense poster grid.
struct MoviesBrowseView: View {

    private let genres = ["All", "Drama", "Action", "Comedy", "Thriller",
                          "Romance", "Sci-Fi", "Horror", "Documentary", "Animation"]

    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @State private var selectedGenre = "All"
    @State private var selectedSectionID: String? = nil
    @State private var curationSections = [PageSection]()
    @State private var movies = [ShowBrowseCard]()
    @State private var curationListings = [AssembledListing]()
    @State private var continueItems = [ProgressItem]()
    @State private var isLoading = true
    private var pageConfig: PlatformBrowseItem { platformConfig.browseItem(id: "movies") }
    private var displayGenres: [String] {
        curationSections.isEmpty ? genres : curationSections.map(\.name)
    }
    private var continueWatchingItems: [ProgressItem] {
        let movieIds = Set(movies.map(\.id))
        return continueItems.filter { item in
            guard let show = item.episode?.season?.show,
                  movieIds.contains(show.id),
                  show.isMovie else {
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

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !pageConfig.enabled {
                PlatformSectionUnavailableView(item: pageConfig)
            } else {
                ScrollView {
                LazyVStack(alignment: .leading, spacing: C.sectionSpacing) {
                    if !curationListings.isEmpty {
                        ForEach(curationHeroListings) { listing in
                            NativeCurationListingView(listing: listing)
                        }
                    }

                    if curationListings.isEmpty || !curationSections.isEmpty {
                        genrePills
                    }

                    if isLoading {
                        movieLoadingGrid
                    } else if movies.isEmpty && curationListings.isEmpty {
                        emptyState
                    } else {
                        if !continueWatchingItems.isEmpty {
                            ProgressExploreCarousel(items: continueWatchingItems, kind: .movies)
                        }
                        if !curationListings.isEmpty {
                            ForEach(curationContentListings) { listing in
                                NativeCurationListingView(listing: listing)
                            }
                        } else {
                            movieGrid
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
            guard pageConfig.enabled else {
                isLoading = false
                return
            }
            await load()
        }
    }

    private var genrePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayGenres, id: \.self) { genre in
                    GenrePill(label: genre, selected: selectedGenre == genre) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGenre = genre
                            if let section = curationSections.first(where: { $0.name == genre }) {
                                selectedSectionID = section.id
                            } else {
                                selectedSectionID = nil
                            }
                        }
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.top, 12)
    }

    private var movieGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 18
        ) {
            ForEach(movies) { movie in
                NavigationLink(value: AppRoute.show(movie.id)) {
                    MoviePosterCard(movie: movie)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var movieLoadingGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 18
        ) {
            ForEach(0..<15, id: \.self) { _ in
                RoundedRectangle(cornerRadius: C.cardRadius)
                    .fill(Color.white.opacity(0.06))
                    .aspectRatio(C.mediaAspectRatio(forContentType: "poster"), contentMode: .fit)
                    .shimmering()
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 44))
                .foregroundStyle(Color.white.opacity(0.2))
            Text(selectedGenre == "All" ? "No movies yet" : "No \(selectedGenre) movies")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Movies will appear here once published.")
                .font(.caption)
                .foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, C.pagePad)
    }

    @MainActor
    private func load() async {
        if let cachedPage = CurationManager.shared.cachedPage(key: "movies", section: selectedSectionID, allowExpired: true), cachedPage.hasCurationSurface {
            applyCurationPage(cachedPage)
            isLoading = false
        } else {
            isLoading = movies.isEmpty && curationListings.isEmpty
        }

        do {
            async let pageTask = CurationManager.shared.fetchPage(key: "movies", section: selectedSectionID)
            async let continueTask = APIClient.shared.fetchContinueWatching()
            let page = try await pageTask
            applyCurationPage(page)
            continueItems = ((try? await continueTask)?.items ?? [])
        } catch {
            if movies.isEmpty && curationListings.isEmpty {
                continueItems = []
                curationSections = []
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
        let curationMovies = sourceItems
            .filter { $0.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "show" }
            .map(\.asShowBrowseCard)
            .uniqueByID()
        movies = curationListings.isEmpty && selectedGenre != "All"
            ? curationMovies.filter { $0.genre?.localizedCaseInsensitiveCompare(selectedGenre) == .orderedSame }
            : curationMovies
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

private struct MoviePosterCard: View {
    let movie: ShowBrowseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                posterImage
                    .aspectRatio(C.mediaAspectRatio(forContentType: "poster"), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
                    .clipped()

                if let rating = movie.contentRating, !rating.isEmpty {
                    Text(rating.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(7)
                }

                EntitlementBadgeView(type: movie.entitlementType ?? "")
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            Text(movie.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(1)

            MovieMetaRow(movie: movie)
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let imageURL = C.mediaURL(movie.coverUrl) {
            CachedRemoteImage(url: imageURL, targetSize: CGSize(width: 120, height: 180)) { image in
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
            Color(hex: "#0F0F17")
            VStack(spacing: 6) {
                Image(systemName: "film")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.white.opacity(0.22))
                Text(movie.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.34))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct MovieMetaRow: View {
    let movie: ShowBrowseCard

    private var durationText: String? {
        guard let duration = movie.movieDuration, duration > 0 else { return nil }
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var body: some View {
        HStack(spacing: 4) {
            if let year = movie.productionYear { Text(year) }
            if movie.productionYear != nil, durationText != nil { Text(".") }
            if let durationText { Text(durationText) }
            if (movie.productionYear != nil || durationText != nil), movie.genre != nil { Text(".") }
            if let genre = movie.genre { Text(genre) }
        }
        .font(.caption2)
        .foregroundStyle(C.textMuted)
        .lineLimit(1)
    }
}

/// Small AVOD/SVOD/PPV badge overlay
struct EntitlementBadgeView: View {
    let type: String

    var body: some View {
        switch type {
        case "SVOD":
            Text("SUB")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(hex: "#7C3AED"))
                .clipShape(Capsule())
        case "PPV":
            Text("RENT")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(hex: "#F59E0B"))
                .clipShape(Capsule())
        default:
            EmptyView()
        }
    }
}
