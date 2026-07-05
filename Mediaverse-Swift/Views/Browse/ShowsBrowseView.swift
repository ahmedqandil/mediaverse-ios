import SwiftUI

/// TV Shows browse page.
/// Mirrors the mobile web /shows route: hero, search mode, New & Popular, and genre rows.
struct ShowsBrowseView: View {

    @State private var allShows = [ShowBrowseCard]()
    @State private var searchResults = [ShowBrowseCard]()
    @State private var query = ""
    @State private var isSearching = false
    @State private var isLoading = true
    @State private var isSearchLoading = false

    private var hero: ShowBrowseCard? { allShows.first }
    private var newAndPopular: [ShowBrowseCard] { Array(allShows.prefix(16)) }

    private var genreRows: [(String, [ShowBrowseCard])] {
        var grouped = [String: [ShowBrowseCard]]()
        for show in allShows {
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

            if isLoading {
                loadingState
            } else if allShows.isEmpty {
                emptyState(title: "No shows yet", subtitle: "Shows will appear here once published.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let hero, !isSearching {
                            ShowsHeroCard(show: hero)
                        }

                        headerAndSearch

                        if isSearching {
                            searchSection
                        } else {
                            ShowsCarousel(title: "New & Popular", shows: newAndPopular, seeAllGenre: nil)

                            ForEach(genreRows, id: \.0) { genre, shows in
                                ShowsCarousel(title: genre, shows: shows, seeAllGenre: genre)
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationTitle("TV Shows")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private var headerAndSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(C.watch)
                Text("TV Shows & Series")
                    .font(.title3.bold())
                    .foregroundStyle(C.text)
            }

            HStack(spacing: 10) {
                TextField("Search shows...", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .font(.subheadline)
                    .foregroundStyle(C.text)
                    .onSubmit { Task { await submitSearch() } }
                    .onChange(of: query) { _, newValue in
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
        .padding(.horizontal, C.pagePad)
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
                    .aspectRatio(16/9, contentMode: .fit)
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
                    .aspectRatio(2/3, contentMode: .fit)
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
        isLoading = true
        do {
            allShows = try await APIClient.shared.fetchShowsBrowse()
        } catch {
            allShows = []
        }
        isLoading = false
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
        do {
            searchResults = try await APIClient.shared.fetchShowsBrowse(q: trimmed)
        } catch {
            searchResults = []
        }
        isSearchLoading = false
    }
}

private struct ShowsHeroCard: View {
    let show: ShowBrowseCard

    var body: some View {
        NavigationLink(value: AppRoute.show(show.id)) {
            ZStack(alignment: .bottomLeading) {
                heroImage
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16/9, contentMode: .fill)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Featured Series")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(C.watch)

                    Text(show.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let genre = show.genre { Text(genre) }
                        if show.genre != nil, let language = show.language { Text("."); Text(language.uppercased()) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.72))

                    if let description = show.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.62))
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
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let imageURL = C.mediaURL(show.bannerUrl ?? show.coverUrl) {
            AsyncImage(url: imageURL) { image in
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

    var body: some View {
        if !shows.isEmpty {
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
                    HStack(spacing: 12) {
                        ForEach(shows) { show in
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

struct ShowPosterCard: View {
    let show: ShowBrowseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                posterImage
                    .frame(width: 116, height: 174)
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

            Text(show.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: 116, alignment: .leading)

            HStack(spacing: 4) {
                if let year = show.productionYear { Text(year) }
                if show.productionYear != nil, show.seasonCount > 0 { Text(".") }
                if show.seasonCount > 0 { Text("\(show.seasonCount) \(show.seasonCount == 1 ? "season" : "seasons")") }
            }
            .font(.caption2)
            .foregroundStyle(C.textMuted)
            .frame(width: 116, alignment: .leading)
        }
        .frame(width: 116, alignment: .leading)
    }

    @ViewBuilder
    private var posterImage: some View {
        if let imageURL = C.mediaURL(show.coverUrl) {
            AsyncImage(url: imageURL) { image in
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
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? C.watch : Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
    }
}

extension View {
    func shimmering() -> some View {
        self.opacity(0.6)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: UUID())
    }
}
