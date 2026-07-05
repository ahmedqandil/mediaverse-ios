import SwiftUI

/// Movies browse page.
/// Mirrors the mobile web /movies route: Watch eyebrow, genre pills, and dense poster grid.
struct MoviesBrowseView: View {

    private let genres = ["All", "Drama", "Action", "Comedy", "Thriller",
                          "Romance", "Sci-Fi", "Horror", "Documentary", "Animation"]

    @State private var selectedGenre = "All"
    @State private var movies = [ShowBrowseCard]()
    @State private var isLoading = true

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    genrePills

                    if isLoading {
                        movieLoadingGrid
                    } else if movies.isEmpty {
                        emptyState
                    } else {
                        movieGrid
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Movies & Films")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Watch · Movies")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(C.watch)
            Text("Movies & Films")
                .font(.title2.bold())
                .foregroundStyle(C.text)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
    }

    private var genrePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    GenrePill(label: genre, selected: selectedGenre == genre) {
                        selectedGenre = genre
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
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
                    .aspectRatio(2/3, contentMode: .fit)
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
        isLoading = true
        do {
            movies = try await APIClient.shared.fetchMoviesBrowse(
                genre: selectedGenre == "All" ? nil : selectedGenre
            )
        } catch {
            movies = []
        }
        isLoading = false
    }
}

private struct MoviePosterCard: View {
    let movie: ShowBrowseCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                posterImage
                    .aspectRatio(2/3, contentMode: .fit)
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
