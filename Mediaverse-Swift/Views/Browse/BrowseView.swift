import SwiftUI

/// Browse landing with explicit in-place section navigation.
/// Each section keeps the filters/search controls from its destination page without
/// turning the whole Browse area into a horizontally paged carousel.
struct BrowseView: View {

    @EnvironmentObject private var platformConfig: PlatformConfigManager
    @State private var selectedSection: BrowseSection = .shows
    @State private var searchPresented = false
    @State private var scrollResetToken = 0
    @State private var curatedBrowseItems: [PlatformBrowseItem]?

    private var platformBrowseItems: [PlatformBrowseItem] {
        let configured = platformConfig.browseSections.filter { BrowseSection(rawValue: $0.id) != nil }
        return configured.isEmpty ? PlatformBrowseItem.defaults : configured
    }

    private var browseItems: [PlatformBrowseItem] {
        curatedBrowseItems ?? platformBrowseItems
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
            Task { await refreshCuratedBrowseItems() }
        }
        .task {
            await refreshCuratedBrowseItems()
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
        case .shows:
            ShowsBrowseView()
        case .videos:
            VideosBrowseView()
        case .movies:
            MoviesBrowseView()
        case .microdramas:
            MicrodramasBrowseView()
        case .channels:
            ChannelsBrowseView()
        case .following:
            FollowingView()
        case .collections:
            CollectionsView()
        }
    }

    @MainActor
    private func refreshCuratedBrowseItems() async {
        let items = await CurationManager.shared.curatedBrowseItems(from: platformBrowseItems)
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
