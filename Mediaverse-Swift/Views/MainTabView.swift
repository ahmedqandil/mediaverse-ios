import SwiftUI
import UIKit
import UserNotifications

/// Root tab container: Home · Browse · Upload · Shorts · Profile
/// All watch/channel/show/microdrama screens are PUSHED on the relevant NavigationStack.
/// On iOS 26 the tab bar adopts Liquid Glass automatically — UITabBar.appearance()
/// is skipped on that OS to avoid fighting the compositor.
struct MainTabView: View {

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @AppStorage("didRequestPushNotifications") private var didRequestPushNotifications = false
    @State private var selectedTab: AppTab = .home
    @State private var homePath: [AppRoute] = []
    @State private var browsePath: [AppRoute] = []
    @State private var uploadPath: [AppRoute] = []
    @State private var shortsPath: [AppRoute] = []
    @State private var profilePath: [AppRoute] = []
    @State private var expandingMiniItem: MiniPlayerManager.Item?
    @State private var isMiniExpanding = false
    @State private var expansionOverlayOpacity: Double = 1
    @State private var miniPlayerDragOffset: CGFloat = 0

    enum AppTab: Int {
        case home, browse, upload, shorts, profile
    }

    private func appTabLabel(_ title: String, icon: String, fallback: String) -> some View {
        Label {
            Text(title)
        } icon: {
            MediaverseIcon(name: icon, fallbackSystemName: fallback)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {

            // ── Home ──────────────────────────────────────────────────────────
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { appTabLabel("Home", icon: "home", fallback: "house") }
            .tag(AppTab.home)

            // ── Browse ────────────────────────────────────────────────────────
            NavigationStack(path: $browsePath) {
                BrowseView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { appTabLabel("Browse", icon: "explore", fallback: "square.grid.2x2") }
            .tag(AppTab.browse)

            // ── Upload ────────────────────────────────────────────────────────
            NavigationStack(path: $uploadPath) {
                UploadView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { appTabLabel("Upload", icon: "upload", fallback: "plus.rectangle") }
            .tag(AppTab.upload)

            // ── Shorts ────────────────────────────────────────────────────────
            NavigationStack(path: $shortsPath) {
                ShortsView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { appTabLabel("Shorts", icon: "short", fallback: "play.rectangle.on.rectangle") }
            .tag(AppTab.shorts)

            // ── Profile ───────────────────────────────────────────────────────
            NavigationStack(path: $profilePath) {
                ProfileView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .tabItem { appTabLabel("Profile", icon: "user", fallback: "person") }
            .tag(AppTab.profile)
            }
            .tint(C.watch)

            if let item = miniPlayer.item, expandingMiniItem == nil {
                MiniWatchPlayer(
                    player: item.player,
                    title: item.title,
                    onExpand: { expandMiniPlayer(item.route) },
                    onClose: { miniPlayer.close() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 92)
                .offset(x: miniPlayerDragOffset)
                .opacity(miniPlayerOpacity)
                .gesture(miniPlayerDismissGesture)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(40)
            }

            if let item = expandingMiniItem {
                expandingMiniOverlay(item)
                    .opacity(expansionOverlayOpacity)
                    .zIndex(60)
            }
        }
        .onAppear {
            // iOS 26 Liquid Glass manages tab bar appearance automatically.
            // Applying UITabBar.appearance() on iOS 26 fights the compositor and
            // breaks the glass effect — only apply the custom dark style on older OS.
            if #available(iOS 26, *) { return }
            applyTabBarAppearance()
        }
        .task {
            await requestPushNotificationsIfNeeded()
        }
        .onChange(of: miniPlayer.expansionAttachToken) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                finishExpansionOverlayIfNeeded()
            }
        }
        .onChange(of: miniPlayer.replaceAndExpandToken) { _, _ in
            guard let item = miniPlayer.item else { return }
            expandMiniPlayer(item.route)
        }
    }

    private var miniPlayerOpacity: Double {
        1 - min(Double(abs(miniPlayerDragOffset) / 190), 0.55)
    }

    private var miniPlayerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let translation = value.translation
                guard abs(translation.width) > abs(translation.height) else { return }
                miniPlayerDragOffset = translation.width
            }
            .onEnded { value in
                let translation = value.translation.width
                let predictedTranslation = value.predictedEndTranslation.width
                let shouldDismiss = abs(translation) > 100 || abs(predictedTranslation) > 150

                if shouldDismiss {
                    dismissMiniPlayer(toward: predictedTranslation == 0 ? translation : predictedTranslation)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        miniPlayerDragOffset = 0
                    }
                }
            }
    }

    private func dismissMiniPlayer(toward translation: CGFloat) {
        let direction: CGFloat = translation < 0 ? -1 : 1
        withAnimation(.easeIn(duration: 0.18)) {
            miniPlayerDragOffset = direction * UIScreen.main.bounds.width
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            miniPlayer.close()
            miniPlayerDragOffset = 0
        }
    }

    private func expandMiniPlayer(_ route: AppRoute) {
        guard let item = miniPlayer.item else { return }
        expandingMiniItem = item
        isMiniExpanding = false
        expansionOverlayOpacity = 1
        miniPlayer.beginExpansionHandoff()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.90, blendDuration: 0.04)) {
                isMiniExpanding = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            miniPlayer.prepareForExpansion()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedTab = .home
                homePath.append(route)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            finishExpansionOverlayIfNeeded()
        }
    }

    private func finishExpansionOverlayIfNeeded() {
        guard expandingMiniItem != nil else { return }
        withAnimation(.easeOut(duration: 0.10)) {
            expansionOverlayOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            expandingMiniItem = nil
            isMiniExpanding = false
            expansionOverlayOpacity = 1
            miniPlayer.finishExpansionHandoff()
        }
    }

    private func expandingMiniOverlay(_ item: MiniPlayerManager.Item) -> some View {
        GeometryReader { geo in
            let miniWidth: CGFloat = 150
            let miniHeight: CGFloat = 84
            let fullWidth = geo.size.width
            let fullHeight = fullWidth * 9 / 16
            let miniY = max(0, geo.size.height - 176)

            WatchPlayerSurface(player: item.player)
                .frame(width: isMiniExpanding ? fullWidth : miniWidth, height: isMiniExpanding ? fullHeight : miniHeight)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: isMiniExpanding ? 0 : 10))
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(y: isMiniExpanding ? 0 : miniY)
                .shadow(color: .black.opacity(isMiniExpanding ? 0 : 0.45), radius: 20, y: 8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func requestPushNotificationsIfNeeded() async {
        guard UIApplication.shared.hasPushNotificationEntitlement else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            guard !didRequestPushNotifications else { return }
            didRequestPushNotifications = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        case .authorized, .provisional, .ephemeral:
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        default:
            break
        }
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id):
            VideoWatchView(videoId: id)
                .id(id)
        case .short(let id, let showId, let channelId):
            ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id):
            EpisodeWatchView(episodeId: id)
                .id(id)
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
