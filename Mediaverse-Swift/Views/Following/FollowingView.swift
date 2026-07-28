import SwiftUI

/// Feed from followed channels and shows — Videos / Shorts / Episodes tabs.
/// Mirrors /src/app/following/page.tsx
struct FollowingView: View {

    let isBrowseActive: Bool

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager

    enum Tab: String, CaseIterable, Identifiable {
        case videos, shorts, episodes
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var selectedTab: Tab = .videos
    @State private var items     = [FollowingFeedItem]()
    @State private var isLoading = true
    @State private var accountGeneration = 0
    init(isBrowseActive: Bool = true) {
        self.isBrowseActive = isBrowseActive
    }
    private var pageConfig: PlatformBrowseItem { platformConfig.browseItem(id: "following") }
    private var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .videos:
                platformConfig.isEnabled("videos", aspect: .feed)
            case .shorts:
                platformConfig.isEnabled("shorts", aspect: .feed)
            case .episodes:
                platformConfig.hasVisibleEpisodeTypes
            }
        }
    }
    private var activeTab: Tab {
        visibleTabs.contains(selectedTab) ? selectedTab : (visibleTabs.first ?? .videos)
    }

    private var videos:   [FollowingFeedItem] { items.filter { $0._kind != "episode" && $0.type != "short" } }
    private var shorts:   [FollowingFeedItem] { items.filter { $0._kind != "episode" && $0.type == "short" } }
    private var episodes: [FollowingFeedItem] { items.filter { $0._kind == "episode" } }

    private func tabItems(_ tab: Tab) -> [FollowingFeedItem] {
        switch tab {
        case .videos:   return videos
        case .shorts:   return shorts
        case .episodes: return episodes
        }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !pageConfig.enabled {
                PlatformSectionUnavailableView(item: pageConfig)
            } else {
                VStack(spacing: 0) {
                tabBar

                if !auth.isAuthenticated {
                    unauthState
                } else if isLoading {
                    ProgressView().tint(C.watch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    tabContent
                }
            }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard isBrowseActive else { return }
            guard pageConfig.enabled else { isLoading = false; return }
            guard auth.isAuthenticated else { isLoading = false; return }
            await load()
        }
        .onChange(of: isBrowseActive) { _, isActive in
            guard isActive, isLoading else { return }
            guard pageConfig.enabled, auth.isAuthenticated else {
                isLoading = false
                return
            }
            Task { await load() }
        }
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            accountGeneration &+= 1
            items = []
            guard isAuthenticated else {
                isLoading = false
                return
            }
            isLoading = true
            guard isBrowseActive, pageConfig.enabled else { return }
            Task { await load() }
        }
    }

    private var tabBar: some View {
        MediaverseUnderlineTabStrip(
            items: visibleTabs.map { tab in
                MediaverseTabItem(id: tab.id, label: tab.label, count: tabItems(tab).count)
            },
            selectedID: activeTab.id,
            fillsWidth: true,
            background: C.surface
        ) { id in
            guard let tab = visibleTabs.first(where: { $0.id == id }) else { return }
            selectedTab = tab
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        let current = tabItems(activeTab)
        if current.isEmpty {
            emptyForTab(activeTab)
        } else {
            switch activeTab {
            case .videos:
                videoGrid(current)
            case .shorts:
                shortsGrid(current)
            case .episodes:
                videoGrid(current)
            }
        }
    }

    private func videoGrid(_ items: [FollowingFeedItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(items) { item in
                    let route: AppRoute = item._kind == "episode"
                        ? .episode(item.id)
                        : .media(id: item.id, type: item.type, channelId: item.channel?.id)
                    NavigationLink(value: route) {
                        FollowingVideoCard(item: item)
                    }
                }
            }
            .padding(C.pagePad)
        }
        .refreshable {
            C.lightHaptic()
            await load()
        }
    }

    private func shortsGrid(_ items: [FollowingFeedItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.short(item.id, showId: nil, channelId: nil)) {
                        FollowingShortCard(item: item)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        ShortNavigationCache.shared.seedIDs(followingShortIDs())
                    })
                }
            }
            .padding(C.pagePad)
        }
        .refreshable {
            C.lightHaptic()
            await load()
        }
    }

    @ViewBuilder
    private func emptyForTab(_ tab: Tab) -> some View {
        let (icon, msg, sub, _, _): (String, String, String, String, String) = {
            switch tab {
            case .videos:   return ("play.rectangle", "No videos yet",  "Follow channels to see their videos here",  "/channels", "Browse channels")
            case .shorts:   return ("iphone",         "No shorts yet",  "Follow channels that post shorts",           "/channels", "Browse channels")
            case .episodes: return ("tv",             "No episodes yet","Follow shows to see new episodes here",      "/shows",    "Discover shows")
            }
        }()

        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text(msg)
                .font(.headline)
                .foregroundStyle(C.text)
            Text(sub)
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unauthState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("Sign in to see who you're following")
                .font(.headline).foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func followingShortIDs() -> [String] {
        shorts.map(\.id)
    }

    private func load() async {
        let generation = accountGeneration
        isLoading = items.isEmpty
        let refreshedItems = (try? await APIClient.shared.fetchFollowingFeed()) ?? []
        guard generation == accountGeneration, auth.isAuthenticated else { return }
        items = refreshedItems
        isLoading = false
    }
}

// MARK: - Cards

private struct FollowingVideoCard: View {
    let item: FollowingFeedItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedRemoteImage(
                url: C.mediaURL(item.thumbnailUrl),
                targetSize: CGSize(width: 220, height: 124)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(C.mediaAspectRatio(forContentType: item._kind ?? item.type ?? "video"), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(C.text)
                .lineLimit(2)

            if let ch = item.channel {
                Text(ch.name)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            } else if let show = item.season?.show {
                Text(show.title)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
        }
    }
}

private struct FollowingShortCard: View {
    let item: FollowingFeedItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedRemoteImage(
                url: C.mediaURL(item.thumbnailUrl),
                targetSize: CGSize(width: 180, height: 320)
            ) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(C.mediaAspectRatio(forContentType: item.type ?? "short"), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(item.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
        }
    }
}
