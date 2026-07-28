import SwiftUI

/// Browse landing with explicit in-place section navigation.
/// Each section keeps the filters/search controls from its destination page without
/// turning the whole Browse area into a horizontally paged carousel.
struct BrowseView: View {

    let isRootActive: Bool

    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @State private var selectedSection: BrowseSection = .discover
    @State private var searchPresented = false
    @State private var scrollResetToken = 0
    @State private var curatedBrowseItems: [PlatformBrowseItem]?
    @State private var discoverListings: [AssembledListing] = []
    @State private var isDiscoverLoading = false
    @State private var discoverError: String?
    @State private var isHorizontalCarouselInteracting = false

    init(isRootActive: Bool = true) {
        self.isRootActive = isRootActive
    }

    private var platformBrowseItems: [PlatformBrowseItem] {
        let configured = platformConfig.browseSections.filter { BrowseSection(rawValue: $0.id) != nil }
        return platformConfig.isLoaded ? configured : PlatformBrowseItem.defaults
    }

    private var browseItems: [PlatformBrowseItem] {
        let categories = curatedBrowseItems ?? platformBrowseItems
        let configured = Dictionary(uniqueKeysWithValues: categories.map {
            (PlatformBrowseItem.normalizedId($0.id), $0)
        })
        let serverDestinations: [(String, String)] = [
            ("shows", "Shows"),
            ("movies", "Movies"),
            ("microdramas", "Microdramas"),
            ("channels", "Channels"),
            ("people", "People"),
            ("vibes", "Vibes"),
            ("events", "Events"),
            ("collections", "Collections")
        ]
        return [PlatformBrowseItem(id: "discover", label: "Discover", enabled: true)]
            + serverDestinations.compactMap { id, _ in
                if let item = configured[id], item.enabled { return item }
                return nil
            }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if browseItems.isEmpty {
                emptyCurationState
            } else {
                VStack(spacing: 0) {
                    sectionTabs

                    selectedContent
                        .id("\(selectedSection.rawValue)-\(scrollResetToken)")
                        .simultaneousGesture(sectionSwipeGesture)
                }
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Discover")
                    .font(.system(size: 17, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchPresented = true
                } label: {
                    MediaverseIcon(name: "search", fallbackSystemName: "magnifyingglass")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(C.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
        }
        .sheet(isPresented: $searchPresented) {
            SearchView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exploreSectionRequested)) { notification in
            guard let rawSection = notification.object as? String,
                  let section = BrowseSection(rawValue: rawSection) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedSection = section
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainTabScrollToTopRequested)) { notification in
            guard (notification.object as? String) == "explore" else { return }
            scrollResetToken += 1
        }
        .onChange(of: platformConfig.browseSections) { _, _ in
            guard isRootActive else { return }
            Task { await refreshCuratedBrowseItems() }
        }
        .task(id: isRootActive) {
            guard isRootActive else { return }
            await refreshCuratedBrowseItems()
        }
        .onAppear {
            ensureSelectedSectionIsVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .horizontalCarouselInteractionChanged)) { notification in
            isHorizontalCarouselInteracting = (notification.object as? Bool) == true
        }
    }

    private var sectionTabs: some View {
        ScrollViewReader { proxy in
            WestreemHorizontalScrollView(showsIndicators: false) {
                MediaverseUnderlineTabStrip(
                    items: browseItems.map {
                        let section = BrowseSection(rawValue: $0.id) ?? .discover
                        return MediaverseTabItem(
                            id: $0.id,
                            label: $0.label,
                            iconName: section.assetIcon,
                            fallbackSystemName: section.fallbackIcon
                        )
                    },
                    selectedID: selectedSection.rawValue,
                    fillsWidth: false,
                    horizontalPadding: C.pagePad,
                    verticalPadding: 11,
                    background: C.bg
                ) { id in
                    guard let section = BrowseSection(rawValue: id) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSection = section
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(selectedSection.rawValue, anchor: .center)
            }
            .onChange(of: selectedSection) { _, section in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(section.rawValue, anchor: .center)
                }
            }
        }
        .background(C.bg.opacity(0.97))
    }

    private var sectionSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                guard !isHorizontalCarouselInteracting else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let predictedHorizontal = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(vertical) * 1.15,
                      abs(horizontal) > 48 || abs(predictedHorizontal) > 80 else { return }
                let direction = abs(predictedHorizontal) > abs(horizontal) ? predictedHorizontal : horizontal
                let sections = browseItems.compactMap { BrowseSection(rawValue: $0.id) }
                guard let index = sections.firstIndex(of: selectedSection) else { return }
                let nextIndex = direction < 0 ? index + 1 : index - 1
                guard sections.indices.contains(nextIndex) else { return }
                C.lightHaptic()
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedSection = sections[nextIndex]
                }
            }
    }

    private var emptyCurationState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text("No curated sections")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Discover sections will appear here once curation is configured.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .discover:
            DiscoverHubView(
                listings: discoverListings,
                isLoading: isDiscoverLoading,
                errorMessage: discoverError,
                availableSections: browseItems.compactMap {
                    guard let section = BrowseSection(rawValue: $0.id),
                          section != .discover,
                          section != .videos else { return nil }
                    return section
                },
                retry: { await refreshCuratedBrowseItems() },
                openSection: { selectedSection = $0 }
            )
        case .shows:
            ShowsBrowseView(isBrowseActive: isRootActive)
        case .videos:
            VideosBrowseView(isBrowseActive: isRootActive)
        case .movies:
            MoviesBrowseView(isBrowseActive: isRootActive)
        case .microdramas:
            MicrodramasBrowseView(isBrowseActive: isRootActive)
        case .channels:
            ChannelsBrowseView(isBrowseActive: isRootActive)
        case .people:
            DiscoverIdentityDirectoryView(
                pageKey: "discover-people",
                title: "People",
                eyebrow: "People to follow",
                description: "Creators and voices worth following."
            )
        case .vibes:
            DiscoverIdentityDirectoryView(
                pageKey: "discover-vibes",
                title: "Vibes",
                eyebrow: "Vibes to explore",
                description: "Communities, conversations, and Ripples."
            )
        case .events:
            VibeEventsView()
        case .collections:
            CollectionsView(isBrowseActive: isRootActive)
        }
    }

    @MainActor
    private func refreshCuratedBrowseItems() async {
        isDiscoverLoading = true
        discoverError = nil
        async let discoverResult = fetchDiscoverPage()
        let items = await CurationManager.shared.curatedBrowseItems(from: platformBrowseItems)
        switch await discoverResult {
        case .success(let page):
            discoverListings = page.activeListings
        case .failure(let error):
            discoverListings = []
            discoverError = Self.discoverErrorMessage(error)
        }
        isDiscoverLoading = false
        curatedBrowseItems = items
        ensureSelectedSectionIsVisible()
    }

    private func fetchDiscoverPage() async -> Result<AssembledPage, Error> {
        do {
            return .success(try await CurationManager.shared.fetchPage(key: "discover"))
        } catch {
            return .failure(error)
        }
    }

    private static func discoverErrorMessage(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return "Discover could not load its curated sections."
    }

    private func ensureSelectedSectionIsVisible() {
        let visibleSections = browseItems.compactMap { BrowseSection(rawValue: $0.id) }
        guard !visibleSections.contains(selectedSection), let first = visibleSections.first else { return }
        selectedSection = first
    }
}

struct PlatformSectionUnavailableView: View {
    let item: PlatformBrowseItem

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text("\(item.label) is unavailable")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("This section is currently hidden by platform configuration.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }
}

private enum BrowseSection: String, CaseIterable, Identifiable {
    case discover
    case shows
    case videos
    case movies
    case microdramas
    case channels
    case people
    case vibes
    case events
    case collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .shows: return "Shows"
        case .videos: return "Videos"
        case .movies: return "Movies"
        case .microdramas: return "Microdramas"
        case .channels: return "Channels"
        case .people: return "People"
        case .vibes: return "Vibes"
        case .events: return "Events"
        case .collections: return "Collections"
        }
    }

    var assetIcon: String {
        switch self {
        case .discover: return "compass"
        case .shows: return "tv"
        case .videos: return "play"
        case .movies: return "film"
        case .microdramas: return "phone"
        case .channels: return "users"
        case .people: return "user"
        case .vibes: return "vibes"
        case .events: return "calendar"
        case .collections: return "library"
        }
    }

    var fallbackIcon: String {
        switch self {
        case .discover: return "safari"
        case .shows: return "tv"
        case .videos: return "play.rectangle"
        case .movies: return "film"
        case .microdramas: return "iphone"
        case .channels: return "rectangle.stack.person.crop"
        case .people: return "person.2"
        case .vibes: return "wave.3.right"
        case .events: return "calendar"
        case .collections: return "square.stack"
        }
    }
}

private struct DiscoverHubView: View {
    let listings: [AssembledListing]
    let isLoading: Bool
    let errorMessage: String?
    let availableSections: [BrowseSection]
    let retry: () async -> Void
    let openSection: (BrowseSection) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: C.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXPLORE WESTREEM")
                        .font(.caption2.bold())
                        .tracking(2)
                        .foregroundStyle(C.watch)
                    Text("Discover")
                        .font(.largeTitle.bold())
                        .fontDesign(.rounded)
                        .foregroundStyle(C.text)
                    Text("Trending topics, Ripples, videos, Shorts, people, Vibes, Shows, and Channels.")
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, C.pagePad)

                destinationGrid

                if isLoading && listings.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: C.cardRadius)
                            .fill(C.surface)
                            .frame(height: 150)
                            .padding(.horizontal, C.pagePad)
                            .redacted(reason: .placeholder)
                    }
                } else if let errorMessage, listings.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t load Discover", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await retry() }
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(C.watch)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, C.pagePad)
                } else if listings.isEmpty {
                    ContentUnavailableView(
                        "Discover is not curated yet",
                        systemImage: "sparkles",
                        description: Text("Browse the categories below while new recommendations are prepared.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, C.pagePad)
                } else {
                    ForEach(listings) { listing in
                        NativeCurationListingView(listing: listing)
                    }
                }

            }
            .padding(.vertical, C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .refreshable { await retry() }
    }

    private var destinationGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            ForEach(availableSections) { section in
                Button {
                    openSection(section)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        MediaverseIcon(name: section.assetIcon, fallbackSystemName: section.fallbackIcon)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(C.watch)
                            .background(C.watch.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.text)
                        Text(destinationDescription(section))
                            .font(.caption2)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .padding(14)
                    .background(C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous)
                            .stroke(C.borderSubtle, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, C.pagePad)
    }

    private func destinationDescription(_ section: BrowseSection) -> String {
        switch section {
        case .shows: "Series, originals, and full seasons"
        case .movies: "Feature films and cinematic releases"
        case .microdramas: "Fast, vertical episodic stories"
        case .channels: "Publishers, creators, and networks"
        case .people: "Creators and voices worth following"
        case .vibes: "Communities, conversations, and Ripples"
        case .events: "Live conversations, watch parties, and premieres"
        case .collections: "Curated sets saved by the community"
        case .discover, .videos: ""
        }
    }
}

private struct DiscoverIdentityDirectoryView: View {
    let pageKey: String
    let title: String
    let eyebrow: String
    let description: String

    @State private var listings: [AssembledListing] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: C.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow.uppercased())
                        .font(.caption2.bold())
                        .tracking(2)
                        .foregroundStyle(C.watch)
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(C.text)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                }
                .padding(.horizontal, C.pagePad)

                if isLoading && listings.isEmpty {
                    ProgressView().tint(C.watch).frame(maxWidth: .infinity).padding(.top, 60)
                } else if let errorMessage, listings.isEmpty {
                    ContentUnavailableView {
                        Label("\(title) could not load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                            .tint(C.watch)
                    }
                } else if listings.isEmpty {
                    ContentUnavailableView(
                        "\(title) has not been curated yet",
                        systemImage: "sparkles",
                        description: Text("Content will appear after an active listing is assigned in Backstage.")
                    )
                } else {
                    ForEach(listings) { NativeCurationListingView(listing: $0) }
                }
            }
            .padding(.vertical, C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .task(id: pageKey) { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = listings.isEmpty
        do {
            let page = try await CurationManager.shared.fetchPage(key: pageKey)
            listings = page.activeListings
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
