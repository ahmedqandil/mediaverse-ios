import SwiftUI

/// Root tab container: Home · Browse · Shorts · Profile
/// All watch/channel/show/microdrama screens are PUSHED on the relevant NavigationStack.
/// On iOS 26 the tab bar adopts Liquid Glass automatically — UITabBar.appearance()
/// is skipped on that OS to avoid fighting the compositor.
struct MainTabView: View {

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @State private var selectedTab: AppTab = .home
    @State private var homePath: [AppRoute] = []
    @State private var browsePath: [AppRoute] = []
    @State private var shortsPath: [AppRoute] = []
    @State private var profilePath: [AppRoute] = []

    enum AppTab: Int {
        case home, browse, shorts, profile
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {

            // ── Home ──────────────────────────────────────────────────────────
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { Label("Home", systemImage: selectedTab == .home ? "house.fill" : "house") }
            .tag(AppTab.home)

            // ── Browse ────────────────────────────────────────────────────────
            NavigationStack(path: $browsePath) {
                BrowseView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { Label("Browse", systemImage: selectedTab == .browse
                ? "square.grid.2x2.fill" : "square.grid.2x2") }
            .tag(AppTab.browse)

            // ── Shorts ────────────────────────────────────────────────────────
            NavigationStack(path: $shortsPath) {
                ShortsView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { Label("Shorts", systemImage: "play.rectangle.on.rectangle") }
            .tag(AppTab.shorts)

            // ── Profile ───────────────────────────────────────────────────────
            NavigationStack(path: $profilePath) {
                ProfileView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { Label("Profile", systemImage: selectedTab == .profile
                ? "person.fill" : "person") }
            .tag(AppTab.profile)
            }
            .tint(C.watch)

            if let item = miniPlayer.item {
                MiniWatchPlayer(
                    player: item.player,
                    title: item.title,
                    onExpand: { expandMiniPlayer(item.route) },
                    onClose: { miniPlayer.close() }
                )
                .padding(.trailing, 12)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .onAppear {
            // iOS 26 Liquid Glass manages tab bar appearance automatically.
            // Applying UITabBar.appearance() on iOS 26 fights the compositor and
            // breaks the glass effect — only apply the custom dark style on older OS.
            if #available(iOS 26, *) { return }
            applyTabBarAppearance()
        }
    }

    private func expandMiniPlayer(_ route: AppRoute) {
        miniPlayer.item = nil
        selectedTab = .home
        homePath.append(route)
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id):
            VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId):
            ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id):
            EpisodeWatchView(episodeId: id)
        case .channel(let handleOrId):
            ChannelView(handle: handleOrId)
        case .show(let id):
            ShowView(showId: id)
        case .microdramaShow(let id):
            MicrodramaShowView(showId: id)
        case .microdramaWatch(let id):
            MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let epNum):
            MicrodramaWatchView(showId: id, startEpisodeNumber: epNum)
        case .playlist(let id):
            PlaylistDetailView(playlistId: id)
        case .collection(let id):
            CollectionDetailView(collectionId: id)
        }
    }

    // MARK: - Tab bar styling (iOS 17 and below only)

    private func applyTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(C.surface)

        let normal = appearance.stackedLayoutAppearance.normal
        normal.iconColor = UIColor(C.textMuted)
        normal.titleTextAttributes = [.foregroundColor: UIColor(C.textMuted)]

        let selected = appearance.stackedLayoutAppearance.selected
        selected.iconColor = UIColor(C.watch)
        selected.titleTextAttributes = [.foregroundColor: UIColor(C.watch)]

        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
