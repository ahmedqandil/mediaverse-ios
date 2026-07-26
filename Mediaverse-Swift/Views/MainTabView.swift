import SwiftUI
import UIKit
import UserNotifications

/// Root page container: Atmosphere · Videos · Shorts · Discover · Me
/// All watch/channel/show/microdrama screens are PUSHED on the relevant NavigationStack.
/// On iOS 26 the tab bar adopts Liquid Glass automatically — UITabBar.appearance()
/// is skipped on that OS to avoid fighting the compositor.
struct MainTabView: View {

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @EnvironmentObject private var globalUploads: GlobalUploadProgressManager
    @AppStorage("playerMuted") private var isMuted: Bool = false
    @StateObject private var shortsPlaybackManager = ShortsPlaybackManager()
    @State private var selectedTab: AppTab = .home
    @State private var lastContentTab: AppTab = .home
    @State private var homePath: [AppRoute] = []
    @State private var videosPath: [AppRoute] = []
    @State private var explorePath: [AppRoute] = []
    @State private var shortsPath: [AppRoute] = []
    @State private var profilePath: [AppRoute] = []
    @State private var isUploadSheetPresented = false
    @State private var uploadDrawerDragOffset: CGFloat = 0
    @State private var expandingMiniItem: MiniPlayerManager.Item?
    @State private var isMiniExpanding = false
    @State private var expansionOverlayOpacity: Double = 1
    @State private var miniPlayerDragOffset: CGFloat = 0
    @State private var isBottomTabBarCompressed = false
    @State private var bottomTabBarRestoreTask: Task<Void, Never>?
    @State private var isCommentsOverlayPresented = false
    @State private var isKeyboardVisible = false
    @State private var isShortsAdPlaybackActive = false
    @State private var isRoutedShortsPresented = false
    @State private var isUploadEligible = false
    private let socialFeatures = SocialFeatureConfiguration.runtime()

    enum AppTab: Int, Hashable {
        case home = 0
        case videos = 1
        case shorts = 2
        case explore = 3
        case profile = 4
    }

    private var activeNavigationPath: [AppRoute] {
        switch selectedTab {
        case .home:
            return homePath
        case .videos:
            return videosPath
        case .shorts:
            return shortsPath
        case .explore:
            return explorePath
        case .profile:
            return profilePath
        }
    }

    private var isPlayerRouteActive: Bool {
        activeNavigationPath.last?.prefersHiddenBottomChrome == true
    }

    private var shouldHideBottomTabBar: Bool {
        isCommentsOverlayPresented || isUploadSheetPresented || isKeyboardVisible || (isPlayerRouteActive && !isRoutedShortsPresented)
    }

    private var isRootTabPagingLocked: Bool {
        selectedTab == .shorts && isShortsAdPlaybackActive
    }

    private func scrollTarget(for tab: AppTab) -> String {
        switch tab {
        case .home:
            return "home"
        case .videos:
            return "home"
        case .shorts:
            return "shorts"
        case .explore:
            return "explore"
        case .profile:
            return "profile"
        }
    }

    private func appTabLabel(_ title: String, icon: String, fallback: String) -> some View {
        Label {
            Text(title)
        } icon: {
            MediaverseIcon(name: icon, fallbackSystemName: fallback)
        }
    }

    var body: some View {
        layeredRoot
        .simultaneousGesture(mainScrollActivityGesture)
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: isUploadSheetPresented)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isBottomTabBarCompressed)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            applyNavigationBarAppearance()
            applyTabBarAppearance()
            consumePendingPushNotificationAction()
        }
        .task {
            scheduleDeferredStartupWork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .storyPublishNotificationTapped)) { _ in
            selectedTab = .home
            lastContentTab = .home
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushRouteRequested)) { notification in
            guard let route = notification.object as? AppRoute else { return }
            _ = PushNotificationManager.shared.consumePendingRoute()
            openPushRoute(route)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { notification in
            shortsPlaybackManager.resetForIdentityChange()
            miniPlayer.close()
            homePath = []
            videosPath = []
            explorePath = []
            shortsPath = []
            profilePath = []
            selectedTab = .home
            lastContentTab = .home
            if let context = notification.object as? ActiveContext {
                routeAfterContextSwitch(context)
            }
            scheduleDeferredContextRefresh(isAuthenticated: auth.isAuthenticated)
        }
        .onReceive(NotificationCenter.default.publisher(for: .uploadRequested)) { _ in
            openUploadOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileTabRequested)) { _ in
            selectedTab = .profile
            lastContentTab = .profile
        }
        .onReceive(NotificationCenter.default.publisher(for: .exploreSectionRequested)) { _ in
            explorePath = []
            selectedTab = .explore
            lastContentTab = .explore
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortsTabRequested)) { _ in
            shortsPath = []
            selectedTab = .shorts
            lastContentTab = .shorts
        }
        .onReceive(NotificationCenter.default.publisher(for: .mentionNavigationRequested)) { notification in
            guard let route = notification.object as? AppRoute else { return }
            pushMentionRoute(route)
        }
        .onReceive(NotificationCenter.default.publisher(for: .commentsOverlayVisibilityChanged)) { notification in
            isCommentsOverlayPresented = (notification.object as? Bool) == true
        }
        .onReceive(NotificationCenter.default.publisher(for: .routedShortsVisibilityChanged)) { notification in
            isRoutedShortsPresented = (notification.object as? Bool) == true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortsAdPlaybackVisibilityChanged), perform: handleShortsAdPlaybackVisibilityChanged)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard UIDevice.current.orientation.isLandscape,
                  let item = miniPlayer.item,
                  item.isAd else { return }
            expandMiniPlayer(item.route)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await PushNotificationManager.shared.retryRegistrationIfAuthorized() }
        }
        .onChange(of: miniPlayer.expansionAttachToken) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                finishExpansionOverlayIfNeeded(force: true)
            }
        }
        .onChange(of: miniPlayer.replaceAndExpandToken) { _, _ in
            guard let item = miniPlayer.item else { return }
            expandMiniPlayer(item.route)
        }
        .onChange(of: selectedTab, handleSelectedTabChange)
        .onChange(of: isMuted) { _, muted in
            shortsPlaybackManager.setMuted(muted)
        }
        .onChange(of: auth.currentUser?.id, handleAuthenticationChange)
    }

    private var layeredRoot: some View {
        ZStack(alignment: .bottom) {
            rootTabView
            bottomTabBarOverlay
            miniPlayerOverlay
            uploadProgressOverlay
            expandingMiniPlayerOverlay
            uploadOptionsOverlay
        }
    }

    @ViewBuilder
    private var bottomTabBarOverlay: some View {
        if !shouldHideBottomTabBar {
            bottomTabBar
                .zIndex(45)
        }
    }

    @ViewBuilder
    private var miniPlayerOverlay: some View {
        if !isCommentsOverlayPresented, let item = miniPlayer.item, expandingMiniItem == nil {
            MiniWatchPlayer(
                player: item.player,
                title: item.title,
                onExpand: {
                    expandMiniPlayer(item.route)
                },
                onClose: { miniPlayer.close() },
                onPlaybackEnded: item.isAd ? {
                    item.adPresentation?.onFinish?()
                    miniPlayer.close()
                } : nil
            )
            .frame(width: 176, height: 99)
            .contentShape(Rectangle())
            .highPriorityGesture(miniPlayerDismissGesture)
            .padding(.trailing, 12)
            .padding(.bottom, C.bottomMenuClearance - 18)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(x: miniPlayerDragOffset)
            .opacity(miniPlayerOpacity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(55)
        }
    }

    @ViewBuilder
    private var uploadProgressOverlay: some View {
        if !isCommentsOverlayPresented, let uploadItem = globalUploads.item {
            GlobalUploadProgressOverlay(item: uploadItem) {
                globalUploads.dismiss()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, miniPlayer.item == nil ? C.bottomMenuClearance - 4 : C.bottomMenuClearance + 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(60)
        }
    }

    @ViewBuilder
    private var expandingMiniPlayerOverlay: some View {
        if let item = expandingMiniItem {
            expandingMiniOverlay(item)
                .opacity(expansionOverlayOpacity)
                .zIndex(80)
        }
    }

    @ViewBuilder
    private var uploadOptionsOverlay: some View {
        if isUploadSheetPresented {
            uploadDrawerOverlay
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(90)
        }
    }

    private var rootTabView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                Group {
                    if socialFeatures.atmosphereEnabled {
                        AtmosphereView()
                    } else {
                        HomeView()
                    }
                }
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .tabItem {
                appTabLabel(
                    socialFeatures.atmosphereEnabled ? "Atmosphere" : "Home",
                    icon: "home",
                    fallback: "house"
                )
            }
            .tag(AppTab.home)

            NavigationStack(path: $videosPath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .ignoresSafeArea(edges: .bottom)
            .tabItem { appTabLabel("Videos", icon: "play", fallback: "play.rectangle") }
            .tag(AppTab.videos)

            NavigationStack(path: $shortsPath) {
                ShortsView(isRootActive: selectedTab == .shorts, playbackManager: shortsPlaybackManager)
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .ignoresSafeArea(edges: .bottom)
            .tabItem { appTabLabel("Shorts", icon: "short", fallback: "play.rectangle.on.rectangle") }
            .tag(AppTab.shorts)

            NavigationStack(path: $explorePath) {
                BrowseView(isRootActive: selectedTab == .explore)
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .ignoresSafeArea(edges: .bottom)
            .tabItem { appTabLabel("Discover", icon: "explore", fallback: "safari") }
            .tag(AppTab.explore)

            NavigationStack(path: $profilePath) {
                ProfileView(isRootActive: selectedTab == .profile)
                    .navigationDestination(for: AppRoute.self) { route in
                        routeDestination(route)
                    }
            }
            .ignoresSafeArea(edges: .bottom)
            .tabItem { appTabLabel("Me", icon: "user", fallback: "person") }
            .tag(AppTab.profile)
        }
        .tint(C.watch)
        .toolbar(.hidden, for: .tabBar)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(edges: .bottom)
        .background(RootTabPagingLock(isLocked: isRootTabPagingLocked))
    }

    private func openUploadOptions() {
        guard auth.isAuthenticated, isUploadEligible else { return }
        C.lightHaptic()
        uploadDrawerDragOffset = 0
        isUploadSheetPresented = true
    }

    private func handleShortsAdPlaybackVisibilityChanged(_ notification: Notification) {
        isShortsAdPlaybackActive = (notification.object as? Bool) == true
    }

    private func scheduleDeferredStartupWork() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            await refreshUploadEligibility()

            try? await Task.sleep(nanoseconds: 250_000_000)
            await prewarmShortsRootFeed()

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainPageWarmupService.shared.prewarm(isAuthenticated: auth.isAuthenticated)
            await PushNotificationManager.shared.requestAuthorizationAndRegister()
        }
    }

    private func scheduleDeferredContextRefresh(isAuthenticated: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refreshUploadEligibility()
            await prewarmShortsRootFeed()

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainPageWarmupService.shared.prewarm(isAuthenticated: isAuthenticated, force: true)
        }
    }

    private func prewarmShortsRootFeed() async {
        let userId = auth.currentUser?.id
        let context = SessionStorage.activeContextCookieValue
        shortsPlaybackManager.prewarmInitialFeed(isMuted: isMuted, userId: userId, context: context)
        await shortsPlaybackManager.prepareRootInitialFeedSnapshot(
            isMuted: isMuted,
            userId: userId,
            context: context
        )
    }

    private func refreshUploadEligibility() async {
        guard auth.isAuthenticated else {
            applyUploadEligibility(false)
            return
        }

        do {
            let contexts = try await UploadOptionsCache.refreshContexts()
            applyUploadEligibility(!contexts.channels.isEmpty || !contexts.shows.isEmpty)
        } catch {
            applyUploadEligibility(false)
        }
    }

    private func applyUploadEligibility(_ isEligible: Bool) {
        isUploadEligible = isEligible
        if !isEligible {
            isUploadSheetPresented = false
        }
        NotificationCenter.default.post(name: .uploadEligibilityChanged, object: isEligible)
    }

    private func handleSelectedTabChange(oldValue: AppTab, newValue: AppTab) {
        if oldValue == .shorts, newValue != .shorts, isShortsAdPlaybackActive {
            selectedTab = .shorts
            return
        }
        if oldValue != newValue {
            C.lightHaptic()
        }
        if oldValue == .shorts, newValue != .shorts {
            shortsPlaybackManager.pausePlayback()
        }
        lastContentTab = newValue
        if newValue != .shorts {
            shortsPlaybackManager.prewarmInitialFeed(
                isMuted: isMuted,
                userId: auth.currentUser?.id,
                context: SessionStorage.activeContextCookieValue
            )
        }
    }

    private func handleAuthenticationChange(oldValue: String?, newValue: String?) {
        shortsPlaybackManager.resetForIdentityChange()
        scheduleDeferredContextRefresh(isAuthenticated: newValue != nil)
    }

    private func dismissUploadOptionsAfterSelection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard isUploadSheetPresented else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                uploadDrawerDragOffset = 360
                isUploadSheetPresented = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                uploadDrawerDragOffset = 0
            }
        }
    }

    private var bottomTabBar: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    bottomTabButton(
                        .home,
                        title: socialFeatures.atmosphereEnabled ? "Atmosphere" : "Home",
                        icon: "home",
                        fallback: "house"
                    )
                    bottomTabButton(.videos, title: "Videos", icon: "play", fallback: "play.rectangle")
                    bottomTabButton(.shorts, title: "Shorts", icon: "short", fallback: "bolt")
                    bottomTabButton(.explore, title: "Discover", icon: "explore", fallback: "safari")
                    bottomTabButton(.profile, title: "Me", icon: "user", fallback: "person")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 392)
                .background(C.elevated.opacity(0.94), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .scaleEffect(isBottomTabBarCompressed ? 0.94 : 1, anchor: .bottom)
                .opacity(isBottomTabBarCompressed ? 0.90 : 1)
                .offset(y: isBottomTabBarCompressed ? 4 : 0)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .allowsHitTesting(true)
    }

    private var mainScrollActivityGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let translation = value.translation
                guard abs(translation.height) > abs(translation.width) * 1.15 else { return }
                bottomTabBarRestoreTask?.cancel()
                bottomTabBarRestoreTask = nil
                if !isBottomTabBarCompressed {
                    isBottomTabBarCompressed = true
                }
            }
            .onEnded { _ in
                scheduleBottomTabBarRestore()
            }
    }

    private func scheduleBottomTabBarRestore() {
        bottomTabBarRestoreTask?.cancel()
        bottomTabBarRestoreTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            isBottomTabBarCompressed = false
            bottomTabBarRestoreTask = nil
        }
    }

    private func bottomTabButton(_ tab: AppTab, title: String, icon: String, fallback: String) -> some View {
        let isSelected = selectedTab == tab
        let color = isSelected ? C.watch : Color.white.opacity(0.35)

        return Button {
            handleBottomTabTap(tab)
        } label: {
            VStack(spacing: 4) {
                MediaverseIcon(name: icon, fallbackSystemName: fallback)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(color)
                    .frame(width: 42, height: 28)

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                Capsule()
                    .fill(isSelected ? C.watch.opacity(0.14) : Color.clear)
            }
            .contentShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .buttonStyle(.plain)
    }

    private func handleBottomTabTap(_ tab: AppTab) {
        if tab == .shorts {
            shortsPlaybackManager.prewarmInitialFeed(
                isMuted: isMuted,
                userId: auth.currentUser?.id,
                context: SessionStorage.activeContextCookieValue
            )
        }
        if selectedTab != tab {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
        } else {
            selectedTab = tab
        }
        lastContentTab = tab
        resetNavigationPath(for: tab)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .mainTabScrollToTopRequested,
                object: scrollTarget(for: tab)
            )
        }
    }

    private func resetNavigationPath(for tab: AppTab) {
        switch tab {
        case .home:
            homePath = []
        case .videos:
            videosPath = []
        case .shorts:
            shortsPath = []
        case .explore:
            explorePath = []
        case .profile:
            profilePath = []
        }
    }

    private var uploadDrawerOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isUploadSheetPresented = false
                }

            UploadView(presentationStyle: .createSheet, onOptionSelected: dismissUploadOptionsAfterSelection)
                .frame(maxWidth: .infinity)
                .background(C.bg)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(C.borderSubtle, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
                .padding(.horizontal, 10)
                .offset(y: uploadDrawerDragOffset)
                .gesture(uploadDrawerDismissGesture)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var uploadDrawerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                uploadDrawerDragOffset = value.translation.height
            }
            .onEnded { value in
                let translation = value.translation.height
                let predictedTranslation = value.predictedEndTranslation.height
                let shouldDismiss = translation > 90 || predictedTranslation > 150

                if shouldDismiss {
                    withAnimation(.easeIn(duration: 0.18)) {
                        uploadDrawerDragOffset = 360
                        isUploadSheetPresented = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        uploadDrawerDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        uploadDrawerDragOffset = 0
                    }
                }
            }
    }

    private var miniPlayerOpacity: Double {
        1 - min(Double(abs(miniPlayerDragOffset) / 190), 0.55)
    }

    private var activeWindowTopSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { scene -> CGFloat? in
                guard let windowScene = scene as? UIWindowScene else { return nil }
                return windowScene.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top
            }
            .first ?? 0
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

    private func pushMentionRoute(_ route: AppRoute) {
        switch selectedTab {
        case .home:
            homePath.append(route)
        case .videos:
            videosPath.append(route)
        case .shorts:
            shortsPath.append(route)
        case .explore:
            explorePath.append(route)
        case .profile:
            profilePath.append(route)
        }
    }

    private func openPushRoute(_ route: AppRoute) {
        miniPlayer.close()
        homePath = []
        videosPath = []
        explorePath = []
        shortsPath = []
        profilePath = []
        isRoutedShortsPresented = route.isShortRoute
        selectedTab = .home
        lastContentTab = .home
        homePath.append(route)
    }

    private func consumePendingPushNotificationAction() {
        if let activationCode = PushNotificationManager.shared.consumePendingDeviceActivationCode() {
            auth.requestDeviceActivation(code: activationCode)
        }
        if let route = PushNotificationManager.shared.consumePendingRoute() {
            openPushRoute(route)
        }
    }

    private func routeAfterContextSwitch(_ context: ActiveContext) {
        switch context.type {
        case "channel":
            homePath.append(.channel(context.channelId ?? context.id))
        case "user":
            selectedTab = .profile
            lastContentTab = .profile
        default:
            break
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

    private func finishExpansionOverlayIfNeeded(force: Bool = false) {
        guard expandingMiniItem != nil else { return }
        guard force || !miniPlayer.isExpansionHandoffActive else { return }
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
            let miniWidth: CGFloat = 176
            let miniHeight: CGFloat = 99
            let miniTrailingPadding: CGFloat = 12
            let miniBottomPadding = C.bottomMenuClearance - 18
            let fullWidth = geo.size.width
            let fullHeight = fullWidth * 9 / 16
            let topInset = max(geo.safeAreaInsets.top, activeWindowTopSafeAreaInset)
            let fallbackFrame = CGRect(
                x: max(0, geo.size.width - miniTrailingPadding - miniWidth),
                y: max(0, geo.size.height - miniBottomPadding - miniHeight),
                width: miniWidth,
                height: miniHeight
            )
            let startFrame = item.sourceFrame ?? fallbackFrame
            let targetFrame = CGRect(
                x: 0,
                y: topInset,
                width: fullWidth,
                height: fullHeight
            )
            let frame = isMiniExpanding ? targetFrame : startFrame

            WatchPlayerSurface(player: item.player)
                .frame(width: frame.width, height: frame.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: isMiniExpanding ? 0 : 10))
                .position(x: frame.midX, y: frame.midY)
                .shadow(color: .black.opacity(isMiniExpanding ? 0 : 0.45), radius: 20, y: 8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id):
            VideoWatchView(videoId: id)
                .id(id)
        case .short(let id, let showId, let channelId):
            ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId, showsDismissControls: true)
        case .episode(let id):
            EpisodeWatchView(episodeId: id)
                .id(id)
        case .channel(let handleOrId):
            ChannelView(handle: handleOrId)
        case .show(let id):
            ShowView(showId: id)
        case .showSeason(let showId, let seasonId):
            ShowView(showId: showId, initialSeasonId: seasonId)
        case .showAccess(let showId, let productId, let intent, let handoffId):
            ShowView(
                showId: showId,
                handoffProductId: productId,
                handoffIntent: intent,
                handoffPublicId: handoffId
            )
            .id("showAccess_\(showId)_\(productId ?? "any")_\(intent ?? "access")_\(handoffId ?? "direct")")
        case .handoff(let id):
            HandoffResolverView(publicId: id)
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
        case .vibe(let slug):
            VibeDetailView(slug: slug)
        case .vibeManagement(let slug, let tab):
            VibeDetailView(slug: slug, initialManagementTab: tab)
        case .vibeInvite(let token):
            VibeInviteAcceptView(token: token)
        case .ripple(let postId):
            RippleDetailView(postId: postId)
        case .atmo(let handle):
            AtmoProfileView(handle: handle)
        case .search(let query):
            SearchView(initialQuery: query)
        }
    }

    // MARK: - App chrome styling

    private func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(C.bg)
        appearance.shadowColor = UIColor(C.borderSubtle)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(C.text)]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(C.text)]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().tintColor = UIColor(C.text)
    }

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

private extension AppRoute {
    var prefersHiddenBottomChrome: Bool {
        switch self {
        case .video, .episode, .microdramaWatch, .microdramaWatchEp:
            return true
        case .short, .channel, .show, .showSeason, .showAccess, .handoff, .microdramaShow, .playlist, .collection,
             .vibe, .vibeManagement, .vibeInvite, .ripple, .atmo, .search:
            return false
        }
    }

    var isShortRoute: Bool {
        if case .short = self { return true }
        return false
    }
}

private struct RootTabPagingLock: UIViewRepresentable {
    let isLocked: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            setHorizontalPagingEnabled(!isLocked, from: view)
        }
    }

    private func setHorizontalPagingEnabled(_ isEnabled: Bool, from marker: UIView) {
        guard let root = marker.window else { return }
        root.allSubviews(of: UIScrollView.self)
            .filter { scrollView in
                scrollView.isPagingEnabled
                    && scrollView.contentSize.width > scrollView.bounds.width + 1
                    && scrollView.contentSize.height <= scrollView.bounds.height + 1
            }
            .forEach { scrollView in
                scrollView.isScrollEnabled = isEnabled
            }
    }
}

private extension UIView {
    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            let matches = subview as? T
            return [matches].compactMap { $0 } + subview.allSubviews(of: type)
        }
    }
}

private struct GlobalUploadProgressOverlay: View {
    let item: GlobalUploadProgressManager.Item
    let onDismiss: () -> Void

    private var iconName: String {
        switch item.state {
        case .active: return "arrow.up.circle.fill"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .active, .complete: return C.watch
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(C.textMuted)
                }

                ProgressView(value: item.progress)
                    .tint(iconColor)
                    .frame(height: 4)

                Text(item.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.textMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}
