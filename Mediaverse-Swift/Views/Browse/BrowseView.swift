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

    init(isRootActive: Bool = true) {
        self.isRootActive = isRootActive
    }

    private var platformBrowseItems: [PlatformBrowseItem] {
        let configured = platformConfig.browseSections.filter { BrowseSection(rawValue: $0.id) != nil }
        return configured.isEmpty ? PlatformBrowseItem.defaults : configured
    }

    private var browseItems: [PlatformBrowseItem] {
        let categories = curatedBrowseItems ?? platformBrowseItems
        return [PlatformBrowseItem(id: "discover", label: "Discover", enabled: true)]
            + categories.filter { BrowseSection(rawValue: $0.id) != .discover }
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
                }
            }
        }
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Explore")
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
        .task {
            guard isRootActive else { return }
            await refreshCuratedBrowseItems()
        }
        .onChange(of: isRootActive) { _, isActive in
            guard isActive else { return }
            Task { await refreshCuratedBrowseItems() }
        }
        .onAppear {
            ensureSelectedSectionIsVisible()
        }
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browseItems) { item in
                    let section = BrowseSection(rawValue: item.id) ?? .shows
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSection = section
                        }
                    } label: {
                        VStack(spacing: 4) {
                            MediaverseIcon(name: section.assetIcon, fallbackSystemName: section.fallbackIcon)
                                .frame(width: 22, height: 22)

                            Text(item.label)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(selectedSection == section ? C.watch : Color.white.opacity(0.35))
                        .frame(width: C.mainTabWidth, height: C.mainTabHeight)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedSection == section ? C.watch.opacity(0.10) : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .animation(.easeInOut(duration: 0.18), value: selectedSection)
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .padding(.vertical, 8)
        .background(C.bg.opacity(0.97))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(C.borderSubtle)
                .frame(height: 0.5)
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
            Text("Explore sections will appear here once curation is configured.")
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
        case .following:
            FollowingView(isBrowseActive: isRootActive)
        case .collections:
            CollectionsView(isBrowseActive: isRootActive)
        }
    }

    @MainActor
    private func refreshCuratedBrowseItems() async {
        isDiscoverLoading = true
        async let discoverTask: AssembledPage? = try? CurationManager.shared.fetchPage(key: "discover")
        let items = await CurationManager.shared.curatedBrowseItems(from: platformBrowseItems)
        discoverListings = await discoverTask?.activeListings ?? []
        isDiscoverLoading = false
        curatedBrowseItems = items
        ensureSelectedSectionIsVisible()
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
    case following
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
        case .following: return "Following"
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
        case .following: return "notification"
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
        case .following: return "bell"
        case .collections: return "square.stack"
        }
    }
}

private struct DiscoverHubView: View {
    let listings: [AssembledListing]
    let isLoading: Bool
    let openSection: (BrowseSection) -> Void

    private let categorySections: [BrowseSection] = [
        .shows, .channels, .movies, .microdramas, .following, .collections
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: C.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
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

                if isLoading && listings.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: C.cardRadius)
                            .fill(C.surface)
                            .frame(height: 150)
                            .padding(.horizontal, C.pagePad)
                            .redacted(reason: .placeholder)
                    }
                } else {
                    ForEach(listings) { listing in
                        NativeCurationListingView(listing: listing)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Browse all")
                        .font(.headline)
                        .foregroundStyle(C.text)
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(categorySections) { section in
                            Button {
                                openSection(section)
                            } label: {
                                HStack(spacing: 10) {
                                    MediaverseIcon(name: section.assetIcon, fallbackSystemName: section.fallbackIcon)
                                        .frame(width: 22, height: 22)
                                        .foregroundStyle(C.watch)
                                    Text(section.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(C.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 54)
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
                }
                .padding(.horizontal, C.pagePad)
            }
            .padding(.vertical, C.pagePad)
            .padding(.bottom, C.bottomMenuClearance)
        }
    }
}
