import SwiftUI

/// Feed from followed channels and shows — Videos / Shorts / Episodes tabs.
/// Mirrors /src/app/following/page.tsx
struct FollowingView: View {

    @EnvironmentObject private var auth: AuthManager

    enum Tab: String, CaseIterable {
        case videos, shorts, episodes
        var label: String { rawValue.capitalized }
    }

    @State private var selectedTab: Tab = .videos
    @State private var items     = [FollowingFeedItem]()
    @State private var isLoading = true

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
            VStack(spacing: 0) {
                // Tab strip
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        TabButton(label: tab.label,
                                  count: tabItems(tab).count,
                                  selected: selectedTab == tab) {
                            selectedTab = tab
                        }
                    }
                }
                .background(C.surface)

                Divider().background(C.border)

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
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard auth.isAuthenticated else { isLoading = false; return }
            await load()
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        let current = tabItems(selectedTab)
        if current.isEmpty {
            emptyForTab(selectedTab)
        } else {
            switch selectedTab {
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
    }

    private func shortsGrid(_ items: [FollowingFeedItem]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.media(id: item.id, type: item.type, channelId: item.channel?.id)) {
                        FollowingShortCard(item: item)
                    }
                }
            }
            .padding(C.pagePad)
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

    private func load() async {
        isLoading = true
        items = (try? await APIClient.shared.fetchFollowingFeed()) ?? []
        isLoading = false
    }
}

// MARK: - Tab button

private struct TabButton: View {
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(.subheadline.weight(selected ? .semibold : .regular))
                if count > 0 {
                    Text("(\(count))").font(.caption2).foregroundStyle(C.textMuted)
                }
            }
            .foregroundStyle(selected ? C.text : C.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .frame(height: 2)
                        .foregroundStyle(C.watch)
                }
            }
        }
    }
}

// MARK: - Cards

private struct FollowingVideoCard: View {
    let item: FollowingFeedItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: C.mediaURL(item.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(16/9, contentMode: .fit)
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
            AsyncImage(url: C.mediaURL(item.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(9/16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius - 2))
            .clipped()

            Text(item.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(C.text)
                .lineLimit(2)
        }
    }
}
