import AVKit
import PhotosUI
import SwiftUI
import UIKit
struct AtmoProfileView: View {
    let handle: String

    var body: some View {
        if SocialFeatureConfiguration.runtime().personalAtmoV2Enabled {
            AtmoV2ProfileSurface(
                target: .handle(handle),
                fallbackHandle: handle
            )
            .id(handle.lowercased())
        } else {
            AtmoUnavailableSurface()
        }
    }
}

/// Retained temporarily as migration-only rollback code. No active Personal
/// Atmo route may render this FanClub-backed surface after the final cutover.
private struct LegacyAtmoProfileView: View {
    private enum Tab: String {
        case atmosphere = "ATMO"
        case echoed = "ECHOED"
        case mentions = "MENTIONS"
        case vibes = "VIBES"
        case about = "ABOUT"

        var feedTab: SocialProfileTab? {
            switch self {
            case .atmosphere: .atmosphere
            case .echoed: .echoed
            case .mentions: .mentions
            case .vibes, .about: nil
            }
        }
    }

    let handle: String
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("playerMuted") private var playerMuted = false
    @StateObject private var autoplay = SocialFeedAutoplayController()
    @State private var selectedTab: Tab = .atmosphere
    @State private var ripples: [Ripple] = []
    @State private var vibes: [VibeSummary] = []
    @State private var availableContentTabs: Set<Tab> = [.atmosphere]
    @State private var cachedRipples: [Tab: [Ripple]] = [:]
    @State private var cachedCursors: [Tab: String] = [:]
    @State private var profile: FullProfile?
    @State private var isSelf = false
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let features = SocialFeatureConfiguration.runtime()

    var body: some View {
        VStack(spacing: 0) {
            profileHeader
            MediaverseUnderlineTabStrip(
                items: tabItems,
                selectedID: selectedTab.rawValue,
                fillsWidth: true,
                horizontalPadding: 0
            ) { value in
                guard let tab = Tab(rawValue: value) else { return }
                selectedTab = tab
                if tab.feedTab == nil {
                    autoplay.stop()
                }
                Task { await load() }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isLoading, ripples.isEmpty {
                        ProgressView().tint(C.watch).padding(.top, 60)
                    } else if selectedTab == .vibes {
                        vibeRows
                    } else if selectedTab == .about {
                        aboutSection
                    } else if ripples.isEmpty {
                        atmosphereEmptyState
                    } else {
                        ForEach(ripples) {
                            RippleCard(
                                ripple: $0,
                                actions: RippleCardActions(
                                    togglePin: isSelf ? pinAction(for: $0) : nil,
                                    isPinned: $0.pinnedAt != nil
                                ),
                                allowsEngagement: features.rippleEngagementEnabled,
                                activePreviewVideoId: $autoplay.activeVideoID,
                                previewManager: autoplay.previewManager,
                                isAutoplayBlocked: isAutoplayBlocked,
                                isPreservingPreviewHandoff: autoplay.isPreservingHandoff,
                                onPreviewPaused: { videoID in
                                    autoplay.suppressAndReselect(
                                        videoID: videoID,
                                        ripples: ripples,
                                        blocked: isAutoplayBlocked
                                    )
                                },
                                onVideoHandoff: handoffToWatch
                            )
                        }
                        if nextCursor != nil {
                            ProgressView().tint(C.watch).task { await loadMore() }
                        }
                    }
                }
                .padding(.vertical, C.pagePad)
                .padding(
                    .horizontal,
                    horizontalSizeClass == .compact && selectedTab.feedTab != nil ? 0 : C.pagePad
                )
                .padding(.bottom, C.bottomMenuClearance)
            }
            .coordinateSpace(name: "homeFeedScroll")
            .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
                guard selectedTab.feedTab != nil else { return }
                autoplay.update(frames: frames, ripples: ripples, blocked: isAutoplayBlocked)
            }
            .refreshable { await load(force: true) }
        }
        .simultaneousGesture(profileTabSwipeGesture)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Text("Account")
                    }
                    .accessibilityLabel("Open Account")
                }
            }
        }
        .task(id: handle) {
            await loadIdentity()
            await discoverProfileTabs()
        }
        .onDisappear { autoplay.stop() }
        .onChange(of: isAutoplayBlocked) { _, blocked in
            autoplay.setBlocked(blocked, ripples: ripples)
        }
        .alert(
            "Atmo unavailable",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var profileTabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.35, abs(horizontal) > 64 else { return }
                let visibleTabs = tabItems.compactMap { Tab(rawValue: $0.id) }
                guard let index = visibleTabs.firstIndex(of: selectedTab) else { return }
                let nextIndex = horizontal < 0 ? index + 1 : index - 1
                guard visibleTabs.indices.contains(nextIndex) else { return }
                C.lightHaptic()
                selectedTab = visibleTabs[nextIndex]
                if selectedTab.feedTab == nil {
                    autoplay.stop()
                }
                Task { await load() }
            }
    }

    private var isAutoplayBlocked: Bool {
        miniPlayer.item != nil || miniPlayer.isExpansionHandoffActive
    }

    private func handoffToWatch(_ video: FeedVideo, _ sourceFrame: CGRect?) {
        let route = AppRoute.media(id: video.id, type: video.type)
        if case .short = route {
            autoplay.stop()
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
            return
        }
        guard let url = C.mediaURL(video.videoUrl) else {
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
            return
        }
        let player = autoplay.previewManager.handoffActivePlayer(for: video.id, muted: playerMuted)
            ?? AVPlayer(url: url)
        player.isMuted = playerMuted
        player.volume = 1
        miniPlayer.replaceAndExpand(
            player: player,
            title: video.title,
            route: route,
            sourceFrame: sourceFrame,
            entrySurface: .atmosphere
        )
    }

    private var tabItems: [MediaverseTabItem] {
        var rows = [MediaverseTabItem(id: Tab.atmosphere.rawValue, label: "Atmo")]
        if availableContentTabs.contains(.echoed) {
            rows.append(MediaverseTabItem(id: Tab.echoed.rawValue, label: "Echoed"))
        }
        if availableContentTabs.contains(.mentions) {
            rows.append(MediaverseTabItem(id: Tab.mentions.rawValue, label: "Mentions"))
        }
        if isSelf, availableContentTabs.contains(.vibes) {
            rows.append(MediaverseTabItem(id: Tab.vibes.rawValue, label: "Vibes"))
        }
        if isSelf, availableContentTabs.contains(.about) {
            rows.append(MediaverseTabItem(id: Tab.about.rawValue, label: "About"))
        }
        return rows
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let bannerURL = profile?.bannerUrl {
                CachedRemoteImage(url: C.mediaURL(bannerURL), targetSize: CGSize(width: 800, height: 240)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(C.elevated)
                }
                .frame(height: 120)
                .clipped()
            }
            HStack(spacing: 12) {
                SocialIdentityAvatar(image: profile?.image, name: profile?.name ?? handle, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.name ?? "@\(handle)")
                        .font(.title3.bold())
                        .foregroundStyle(C.text)
                    Text("@\(profile?.handle ?? handle)")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                if isSelf {
                    Text("My Atmo")
                        .font(.caption.bold())
                        .foregroundStyle(C.watch)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(C.watch.opacity(0.12), in: Capsule())
                }
            }
            .padding(C.pagePad)
        }
        .background(C.surface)
    }

    @MainActor
    private func discoverProfileTabs() async {
        isLoading = true
        var available: Set<Tab> = [.atmosphere]

        do {
            let page = try await api.discover(
                mode: .latest,
                authorHandle: handle,
                profileTab: .atmosphere
            )
            cachedRipples[.atmosphere] = page.posts
            updateCachedCursor(page.nextCursor, for: .atmosphere)
            ripples = page.posts
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            cachedRipples[.atmosphere] = []
            ripples = []
            nextCursor = nil
            errorMessage = socialErrorMessage(error)
        }

        for tab in [Tab.echoed, Tab.mentions] {
            guard let feedTab = tab.feedTab,
                  let page = try? await api.discover(
                    mode: .latest,
                    authorHandle: handle,
                    profileTab: feedTab
                  ) else { continue }
            cachedRipples[tab] = page.posts
            updateCachedCursor(page.nextCursor, for: tab)
            if !page.posts.isEmpty {
                available.insert(tab)
            }
        }

        if isSelf {
            if let page = try? await api.myVibes() {
                vibes = page.clubs
                if !page.clubs.isEmpty {
                    available.insert(.vibes)
                }
            }
            if let bio = profile?.bio?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bio.isEmpty {
                available.insert(.about)
            }
        }

        availableContentTabs = available
        if !available.contains(selectedTab) {
            selectedTab = .atmosphere
        }
        isLoading = false
    }

    private func load(force: Bool = false) async {
        isLoading = true
        do {
            if selectedTab == .vibes {
                let page = try await api.myVibes()
                vibes = page.clubs
                ripples = []
                nextCursor = nil
                errorMessage = nil
                isLoading = false
                return
            }
            if selectedTab == .about {
                ripples = []
                nextCursor = nil
                errorMessage = nil
                isLoading = false
                return
            }
            guard let feedTab = selectedTab.feedTab else { return }
            if !force, let cached = cachedRipples[selectedTab] {
                ripples = cached
                nextCursor = cachedCursors[selectedTab]
                errorMessage = nil
                isLoading = false
                return
            }
            let page = try await api.discover(
                mode: .latest,
                authorHandle: handle,
                profileTab: feedTab
            )
            ripples = page.posts
            nextCursor = page.nextCursor
            cachedRipples[selectedTab] = page.posts
            updateCachedCursor(page.nextCursor, for: selectedTab)
            errorMessage = nil
        } catch {
            ripples = []
            nextCursor = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor, let feedTab = selectedTab.feedTab else { return }
        do {
            let page = try await api.discover(
                mode: .latest,
                cursor: cursor,
                authorHandle: handle,
                profileTab: feedTab
            )
            let existing = Set(ripples.map(\.id))
            ripples.append(contentsOf: page.posts.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
            cachedRipples[selectedTab] = ripples
            updateCachedCursor(page.nextCursor, for: selectedTab)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    @MainActor
    private func loadIdentity() async {
        guard auth.isAuthenticated,
              let response = try? await APIClient.shared.fetchProfile(),
              response.profile.handle?.caseInsensitiveCompare(handle) == .orderedSame else {
            profile = nil
            isSelf = false
            return
        }
        profile = response.profile
        isSelf = true
    }

    private func pinAction(for ripple: Ripple) -> () -> Void {
        {
            Task {
                do {
                    _ = try await api.setRipplePinned(
                        postId: ripple.id,
                        pinned: ripple.pinnedAt == nil
                    )
                    await load(force: true)
                } catch {
                    errorMessage = socialErrorMessage(error)
                }
            }
        }
    }

    private func updateCachedCursor(_ cursor: String?, for tab: Tab) {
        if let cursor {
            cachedCursors[tab] = cursor
        } else {
            cachedCursors.removeValue(forKey: tab)
        }
    }

    private var atmosphereEmptyState: some View {
        ContentUnavailableView {
            Label("This Atmosphere has no Ripples yet", systemImage: "wave.3.right")
        } description: {
            Text(isSelf
                 ? "Create your first Ripple to start shaping your Atmosphere."
                 : "When this person shares a Ripple, it will appear here.")
        }
        .foregroundStyle(C.text)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 56)
    }

    @ViewBuilder
    private var vibeRows: some View {
        if vibes.isEmpty {
            SocialUnavailable(
                title: "No Vibes yet",
                message: "Vibes you create or join will appear here.",
                retry: { Task { await load() } }
            )
        } else {
            ForEach(vibes) { vibe in
                NavigationLink(value: AppRoute.vibe(vibe.slug)) {
                    HStack(spacing: 12) {
                        SocialIdentityAvatar(image: vibe.avatarURL, name: vibe.name, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vibe.name).font(.subheadline.bold()).foregroundStyle(C.text)
                            if let description = vibe.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(C.textTertiary)
                    }
                    .padding(12)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About").font(.headline).foregroundStyle(C.text)
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio).font(.body).foregroundStyle(C.text)
            } else {
                Text("No bio has been added yet.")
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
    }
}

/// Resolves the signed-in user's public Atmo before presenting the Profile tab.
/// The legacy profile/settings experience remains available as Account.
struct MyAtmoProfileView: View {
    let isRootActive: Bool

    @EnvironmentObject private var auth: AuthManager
    @State private var handle: String?
    @State private var userID: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                ProfileView(isRootActive: isRootActive)
            } else if let handle, !handle.isEmpty {
                if SocialFeatureConfiguration.runtime().personalAtmoV2Enabled,
                   let userID, !userID.isEmpty {
                    AtmoV2ProfileSurface(
                        userID: userID,
                        fallbackHandle: handle
                    )
                    // StateObject identity must follow the immutable Westreem
                    // account. Otherwise an in-place account switch can retain
                    // the previous user's Atmo repository and rendered data.
                    .id(userID)
                } else {
                    AtmoUnavailableSurface()
                }
            } else if isLoading {
                ProgressView()
                    .tint(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.bg)
            } else {
                ContentUnavailableView {
                    Label("Atmo unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(errorMessage ?? "Add a handle in Account to activate your public Atmo.")
                } actions: {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Text("Open Account")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)

                    Button("Try Again") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(C.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(C.bg)
            }
        }
        .task(id: auth.currentUser?.id) {
            guard isRootActive else { return }
            await load()
        }
        .onChange(of: isRootActive) { _, active in
            guard active else { return }
            Task { await load() }
        }
        .onChange(of: auth.isAuthenticated) { _, authenticated in
            guard authenticated, isRootActive else {
                handle = nil
                return
            }
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard auth.isAuthenticated else {
            handle = nil
            userID = nil
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        do {
            let response = try await APIClient.shared.fetchProfile()
            handle = response.profile.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
            userID = response.profile.id
            errorMessage = handle?.isEmpty == false ? nil : "Add a handle in Account to activate your public Atmo."
        } catch {
            handle = nil
            userID = nil
            errorMessage = "Your Atmo could not be loaded. Please try again."
        }
        isLoading = false
    }
}

private struct AtmoUnavailableSurface: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                "Personal Atmo unavailable",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(
                "Westreem cannot safely fall back to the retired mixed Vibe and Fan Club profile. Try again after Personal Atmo is enabled."
            )
        }
        .foregroundStyle(C.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }
}

/// Personal Atmo v2 is deliberately isolated from community Vibes and Matrix.
/// A server-authority probe must succeed before this surface renders any data.
private enum AtmoV2ProfileTarget: Hashable {
    case userID(String)
    case handle(String)
}

private struct AtmoV2ProfileSurface: View {
    let target: AtmoV2ProfileTarget
    let fallbackHandle: String

    @StateObject private var model: AtmoV2ProfileViewModel

    init(
        userID: String,
        fallbackHandle: String
    ) {
        self.target = .userID(userID)
        self.fallbackHandle = fallbackHandle
        _model = StateObject(wrappedValue: AtmoV2ProfileViewModel(target: .userID(userID)))
    }

    init(
        target: AtmoV2ProfileTarget,
        fallbackHandle: String
    ) {
        self.target = target
        self.fallbackHandle = fallbackHandle
        _model = StateObject(wrappedValue: AtmoV2ProfileViewModel(target: target))
    }

    var body: some View {
        Group {
            switch model.cutover {
            case .probing:
                ProgressView("Loading Atmo…")
                    .tint(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.bg)
            case .unavailable:
                AtmoUnavailableSurface()
            case .v2:
                v2Body
            }
        }
        .task(id: target) { await model.probeAndLoad() }
    }

    private var v2Body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let profile = model.profile {
                    AtmoV2ProfileHeader(
                        response: profile,
                        isBusy: model.isBusy("follow:\(profile.user.id)"),
                        follow: profile.viewer.owner ? nil : { Task { await model.toggleFollow() } }
                    )
                    if profile.viewer.owner {
                        AtmoV2Composer(model: model)
                    }
                }
                if model.posts.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "This Atmo has no Ripples yet",
                        systemImage: "wave.3.right",
                        description: Text("New public Ripples will appear here.")
                    )
                    .foregroundStyle(C.text)
                    .padding(.vertical, 48)
                }
                ForEach(model.posts) { post in
                    AtmoV2PostCard(
                        post: post,
                        isOwner: model.profile?.viewer.owner == true,
                        model: model
                    )
                }
                if model.nextCursor != nil {
                    ProgressView().tint(C.watch).task { await model.loadMore() }
                }
            }
            .padding(.vertical, C.pagePad)
        }
        .refreshable { await model.reload() }
        .background(C.bg)
        .navigationTitle("@\(model.profile?.user.handle ?? fallbackHandle)")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.red.opacity(0.9), in: Capsule())
                    .padding()
            }
        }
    }
}

@MainActor
private final class AtmoV2ProfileViewModel: ObservableObject {
    enum Cutover { case probing, unavailable, v2 }
    enum Action {
        case pin
        case energy(AtmoV2EnergyDraft?)
        case vote([String])
        case comment(String, parentID: String?)
        case share
        case edit(body: String?, spoiler: Bool, commentsDisabled: Bool)
        case delete
        case echo(quote: String?)
    }

    @Published var cutover: Cutover = .probing
    @Published var profile: AtmoV2ProfileResponse?
    @Published var posts: [AtmoV2Post] = []
    @Published var nextCursor: String?
    @Published var isLoading = false
    @Published private(set) var busyKeys: Set<String> = []
    @Published private(set) var commentsByPost: [String: [AtmoV2Comment]] = [:]
    @Published private(set) var commentCursorByPost: [String: String] = [:]
    @Published var errorMessage: String?

    private let target: AtmoV2ProfileTarget
    private var resolvedUserID: String?
    private let repository: WestreemAtmoV2Repository

    init(target: AtmoV2ProfileTarget) {
        self.target = target
        repository = WestreemAtmoV2Repository(
            transport: APIClient.shared,
            rollout: AtmoV2Rollout(localEnabled: true)
        )
    }

    func isBusy(_ key: String) -> Bool {
        busyKeys.contains(key)
    }

    func probeAndLoad() async {
        guard cutover == .probing else { return }
        do {
            let resolved = try await resolveProfile()
            self.profile = resolved
            resolvedUserID = resolved.user.id
            let result = try await repository.posts(userID: resolved.user.id)
            posts = result.posts
            nextCursor = result.nextCursor
            cutover = .v2
        } catch {
            // A disabled, unavailable, incompatible, or not-yet-migrated server
            // must fail closed. It may never reactivate the FanClub-backed
            // Personal Atmo authority.
            errorMessage = "Personal Atmo is temporarily unavailable."
            cutover = .unavailable
        }
    }

    func reload() async {
        guard cutover == .v2 else { return }
        isLoading = true
        do {
            let resolved = try await resolveProfile()
            self.profile = resolved
            resolvedUserID = resolved.user.id
            let result = try await repository.posts(userID: resolved.user.id)
            posts = result.posts
            nextCursor = result.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = "Atmo could not be refreshed."
        }
        isLoading = false
    }

    func loadMore() async {
        guard let cursor = nextCursor, let userID = resolvedUserID, !isLoading else { return }
        isLoading = true
        do {
            let page = try await repository.posts(userID: userID, cursor: cursor)
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "More Ripples could not be loaded."
        }
        isLoading = false
    }

    @discardableResult
    func publish(_ draft: AtmoV2PostDraft) async -> Bool {
        let key = "publish"
        guard begin(key) else { return false }
        defer { end(key) }
        do {
            let post = try await repository.create(draft)
            posts.insert(post, at: 0)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Ripple could not be published."
            return false
        }
    }

    func toggleFollow() async {
        guard let current = profile, let userID = resolvedUserID else { return }
        let key = "follow:\(userID)"
        guard begin(key) else { return }
        defer { end(key) }
        let original = current
        do {
            _ = try await repository.setFollowing(
                userID: userID, following: !current.viewer.following
            )
            profile = try await repository.profile(userID: userID)
        } catch {
            profile = original
            errorMessage = "Follow could not be updated."
        }
    }

    func perform(_ action: Action, on post: AtmoV2Post) async {
        let key = actionKey(action, postID: post.id)
        guard begin(key) else { return }
        defer { end(key) }
        do {
            switch action {
            case .pin:
                _ = try await repository.setPinned(postID: post.id, pinned: post.pinnedAt == nil)
                let refreshed = try await repository.profile(userID: resolvedUserID ?? post.author.id)
                profile = refreshed
                let page = try await repository.posts(userID: post.author.id)
                posts = page.posts
                nextCursor = page.nextCursor
            case .energy(let energy):
                replace(try await repository.setEnergy(postID: post.id, energy: energy))
            case .vote(let optionIDs):
                replace(try await repository.vote(postID: post.id, optionIDs: optionIDs))
            case .comment(let content, let parentID):
                let comment = try await repository.addComment(
                    postID: post.id, content: content, parentID: parentID
                )
                commentsByPost[post.id, default: []].append(comment)
                replaceCount(postID: post.id, comments: post.counts.comments + 1)
            case .share:
                try await repository.recordShare(postID: post.id, channel: "ios_share")
            case .edit(let body, let spoiler, let commentsDisabled):
                replace(try await repository.edit(
                    postID: post.id,
                    body: body,
                    isSpoiler: spoiler,
                    commentsDisabled: commentsDisabled
                ))
            case .delete:
                try await repository.delete(postID: post.id)
                posts.removeAll { $0.id == post.id }
            case .echo(let quote):
                let created = try await repository.create(
                    AtmoV2PostDraft(
                        body: quote,
                        echo: AtmoV2EchoDraft(
                            sourceType: "ATMO_POST",
                            sourceId: post.id,
                            sourceUrl: publicURL(for: post)?.absoluteString,
                            quote: quote
                        )
                    )
                )
                if profile?.viewer.owner == true {
                    posts.insert(created, at: 0)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "That action could not be completed."
        }
    }

    func uploadPhoto(data: Data, mimeType: String = "image/jpeg") async throws -> AtmoV2AttachmentDraft {
        let ticket = try await repository.requestPhotoUpload(mimeType: mimeType, bytes: data.count)
        guard let uploadURL = URL(string: ticket.uploadUrl),
              uploadURL.scheme?.lowercased() == "https",
              uploadURL.host?.isEmpty == false else {
            throw AtmoV2RepositoryError.invalidAuthority
        }
        try await StoriesAPIClient.shared.uploadMedia(
            to: uploadURL,
            data: data,
            mimeType: mimeType,
            onProgress: { _ in }
        )
        return AtmoV2AttachmentDraft(
            type: "IMAGE",
            imageUrl: ticket.deliveryUrl,
            mediaUrl: ticket.deliveryUrl,
            mediaObjectKey: ticket.objectKey,
            mediaMimeType: mimeType,
            mediaBytes: data.count
        )
    }

    func loadComments(postID: String, append: Bool = false) async {
        let key = "comments:\(postID)"
        guard begin(key) else { return }
        defer { end(key) }
        do {
            let page = try await repository.comments(
                postID: postID,
                cursor: append ? commentCursorByPost[postID] : nil
            )
            if append {
                let existing = Set(commentsByPost[postID, default: []].map(\.id))
                commentsByPost[postID, default: []].append(
                    contentsOf: page.comments.filter { !existing.contains($0.id) }
                )
            } else {
                commentsByPost[postID] = page.comments
            }
            if let cursor = page.nextCursor {
                commentCursorByPost[postID] = cursor
            } else {
                commentCursorByPost.removeValue(forKey: postID)
            }
        } catch {
            errorMessage = "Comments could not be loaded."
        }
    }

    @discardableResult
    func addComment(post: AtmoV2Post, content: String, parentID: String?) async -> Bool {
        let key = "comment-add:\(post.id)"
        guard begin(key) else { return false }
        defer { end(key) }
        do {
            let comment = try await repository.addComment(
                postID: post.id, content: content, parentID: parentID
            )
            commentsByPost[post.id, default: []].append(comment)
            replaceCount(postID: post.id, comments: post.counts.comments + 1)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Comment could not be posted. Your draft was kept."
            return false
        }
    }

    func editComment(_ comment: AtmoV2Comment, content: String) async {
        let key = "comment-edit:\(comment.id)"
        guard begin(key) else { return }
        defer { end(key) }
        do {
            replaceComment(try await repository.editComment(commentID: comment.id, content: content))
        } catch {
            errorMessage = "Comment could not be updated."
        }
    }

    func deleteComment(_ comment: AtmoV2Comment) async {
        let key = "comment-delete:\(comment.id)"
        guard begin(key) else { return }
        defer { end(key) }
        do {
            try await repository.deleteComment(commentID: comment.id)
            commentsByPost[comment.postId]?.removeAll { $0.id == comment.id }
        } catch {
            errorMessage = "Comment could not be deleted."
        }
    }

    func toggleCommentLike(_ comment: AtmoV2Comment) async {
        let key = "comment-like:\(comment.id)"
        guard begin(key) else { return }
        defer { end(key) }
        do {
            let state = try await repository.setCommentLiked(
                commentID: comment.id, liked: !comment.likedByViewer
            )
            guard var values = commentsByPost[comment.postId],
                  let index = values.firstIndex(where: { $0.id == comment.id }) else { return }
            values[index] = AtmoV2Comment(
                id: comment.id, postId: comment.postId, parentId: comment.parentId,
                content: comment.content, likeCount: state.1, likedByViewer: state.0,
                editedAt: comment.editedAt, createdAt: comment.createdAt, author: comment.author
            )
            commentsByPost[comment.postId] = values
        } catch {
            errorMessage = "Comment like could not be updated."
        }
    }

    private func replace(_ post: AtmoV2Post) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index] = post
    }

    private func replaceComment(_ comment: AtmoV2Comment) {
        guard var values = commentsByPost[comment.postId],
              let index = values.firstIndex(where: { $0.id == comment.id }) else { return }
        values[index] = comment
        commentsByPost[comment.postId] = values
    }

    private func replaceCount(postID: String, comments: Int) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let post = posts[index]
        posts[index] = AtmoV2Post(
            id: post.id, body: post.body, status: post.status, isSpoiler: post.isSpoiler,
            commentsDisabled: post.commentsDisabled, pinnedAt: post.pinnedAt,
            editedAt: post.editedAt, publishedAt: post.publishedAt, createdAt: post.createdAt,
            updatedAt: post.updatedAt, author: post.author,
            counts: AtmoV2PostCounts(
                comments: comments, echoes: post.counts.echoes,
                energy: post.counts.energy, shares: post.counts.shares
            ),
            energy: post.energy, attachments: post.attachments, poll: post.poll, echo: post.echo
        )
    }

    private func publicURL(for post: AtmoV2Post) -> URL? {
        guard let handle = post.author.handle else { return nil }
        var components = URLComponents(string: "\(C.baseURL)/atmo/\(C.pathSegment(handle))")
        components?.queryItems = [URLQueryItem(name: "post", value: post.id)]
        return components?.url
    }

    private func begin(_ key: String) -> Bool {
        guard !busyKeys.contains(key) else { return false }
        busyKeys.insert(key)
        return true
    }

    private func end(_ key: String) {
        busyKeys.remove(key)
    }

    private func actionKey(_ action: Action, postID: String) -> String {
        switch action {
        case .pin: "pin:\(postID)"
        case .energy: "energy:\(postID)"
        case .vote: "vote:\(postID)"
        case .comment: "comment-add:\(postID)"
        case .share: "share:\(postID)"
        case .edit: "edit:\(postID)"
        case .delete: "delete:\(postID)"
        case .echo: "echo:\(postID)"
        }
    }

    private func resolveProfile() async throws -> AtmoV2ProfileResponse {
        switch target {
        case .userID(let userID):
            return try await repository.profile(userID: userID)
        case .handle(let handle):
            return try await repository.profile(handle: handle)
        }
    }
}

private struct AtmoV2ProfileHeader: View {
    let response: AtmoV2ProfileResponse
    let isBusy: Bool
    let follow: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedRemoteImage(
                url: C.mediaURL(response.user.bannerUrl),
                targetSize: CGSize(width: 800, height: 240)
            ) { $0.resizable().scaledToFill() } placeholder: {
                LinearGradient(
                    colors: [C.watch.opacity(0.25), C.elevated],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .frame(height: 120).clipped()
            HStack(spacing: 12) {
                SocialIdentityAvatar(
                    image: response.user.image,
                    name: response.user.name ?? response.user.handle ?? "Atmo",
                    size: 64
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(response.user.name ?? "Atmo").font(.title3.bold()).foregroundStyle(C.text)
                    if let handle = response.user.handle {
                        Text("@\(handle)").font(.caption).foregroundStyle(C.textMuted)
                    }
                    Text("\(response.profile.followerCount) followers · \(response.profile.postCount) Ripples")
                        .font(.caption2).foregroundStyle(C.textTertiary)
                }
                Spacer()
                if let follow {
                    Button(response.viewer.following ? "Following" : "Follow", action: follow)
                        .buttonStyle(.borderedProminent).tint(C.watch).disabled(isBusy)
                } else {
                    Text("My Atmo").font(.caption.bold()).foregroundStyle(C.watch)
                }
            }
            .padding(C.pagePad)
            if let bio = response.user.bio, !bio.isEmpty {
                Text(bio).font(.subheadline).foregroundStyle(C.textMuted)
                    .padding(.horizontal, C.pagePad).padding(.bottom, C.pagePad)
            }
        }
        .background(C.surface)
    }
}

private struct AtmoV2Composer: View {
    @ObservedObject var model: AtmoV2ProfileViewModel
    @State private var text = ""
    @State private var photos: [AtmoV2AttachmentDraft] = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var showPoll = false
    @State private var pollQuestion = ""
    @State private var pollOptions = ["", ""]
    @State private var allowsMultiple = false
    @State private var pollResultsVisibility = "AFTER_VOTE"
    @State private var allowsVoteChanges = true
    @State private var pollHasClose = false
    @State private var pollClosesAt = Date().addingTimeInterval(86_400)
    @State private var isSpoiler = false
    @State private var commentsDisabled = false

    private var canPublish: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !photos.isEmpty ||
        validPoll != nil
    }

    private var validPoll: AtmoV2PollDraft? {
        guard showPoll else { return nil }
        let question = pollQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = pollOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !question.isEmpty,
              options.count >= 2,
              Set(options.map { $0.lowercased() }).count == options.count else {
            return nil
        }
        return AtmoV2PollDraft(
            question: question,
            options: options,
            allowsMultiple: allowsMultiple,
            maxSelections: allowsMultiple ? min(options.count, 3) : 1,
            allowsVoteChanges: allowsVoteChanges,
            resultsVisibility: pollResultsVisibility,
            closesAt: pollHasClose ? ISO8601DateFormatter().string(from: pollClosesAt) : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Create a Ripple on My Atmo…", text: $text, axis: .vertical)
                .lineLimit(2...8).textFieldStyle(.plain).foregroundStyle(C.text)
                .accessibilityLabel("Ripple text")

            if !photos.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(photos.indices, id: \.self) { index in
                        ZStack(alignment: .topTrailing) {
                            if let image = photos[index].imageUrl {
                                CachedRemoteImage(
                                    url: C.mediaURL(image),
                                    targetSize: CGSize(width: 360, height: 260)
                                ) {
                                    $0.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(C.elevated)
                                }
                                .frame(height: 130).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Button {
                                photos.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.bold())
                                    .padding(7)
                                    .background(.black.opacity(0.7), in: Circle())
                            }
                            .foregroundStyle(.white)
                            .padding(6)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                    }
                }
                Text("\(photos.count) of 10 photos")
                    .font(.caption2).foregroundStyle(C.textTertiary)
            }

            if showPoll {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Poll").font(.subheadline.bold()).foregroundStyle(C.text)
                        Spacer()
                        Button("Dismiss") {
                            showPoll = false
                        }
                        .font(.caption)
                    }
                    TextField("Ask a question", text: $pollQuestion)
                    ForEach(pollOptions.indices, id: \.self) { index in
                        HStack {
                            TextField("Option \(index + 1)", text: $pollOptions[index])
                            if pollOptions.count > 2 {
                                Button {
                                    pollOptions.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel("Remove option \(index + 1)")
                            }
                        }
                    }
                    HStack {
                        if pollOptions.count < 10 {
                            Button("Add option") { pollOptions.append("") }
                        }
                        Spacer()
                        Toggle("Multiple choices", isOn: $allowsMultiple)
                            .labelsHidden()
                        Text("Multiple choices").font(.caption).foregroundStyle(C.textMuted)
                    }
                    Picker("Results", selection: $pollResultsVisibility) {
                        Text("Always").tag("ALWAYS")
                        Text("After vote").tag("AFTER_VOTE")
                        Text("After close").tag("AFTER_CLOSE")
                    }
                    Toggle("Allow vote changes", isOn: $allowsVoteChanges)
                    Toggle("Set closing time", isOn: $pollHasClose)
                    if pollHasClose {
                        DatePicker(
                            "Closes",
                            selection: $pollClosesAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .background(C.elevated, in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 14) {
                PhotosPicker(
                    selection: $photoSelections,
                    maxSelectionCount: max(0, 10 - photos.count),
                    matching: .images
                ) {
                    Label(isUploading ? "Uploading…" : "Photos", systemImage: "photo.on.rectangle")
                }
                .disabled(isUploading || photos.count >= 10)
                Button {
                    showPoll.toggle()
                } label: {
                    Label("Poll", systemImage: "chart.bar")
                }
                Menu {
                    Toggle("Mark as spoiler", isOn: $isSpoiler)
                    Toggle("Disable comments", isOn: $commentsDisabled)
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                Spacer()
                Button("Ripple") { Task { await publish() } }
                    .buttonStyle(.borderedProminent).tint(C.watch)
                    .disabled(model.isBusy("publish") || isUploading || !canPublish)
            }
            .font(.caption.bold())
            .foregroundStyle(C.textMuted)
        }
        .padding(14)
        .background(C.surface, in: RoundedRectangle(cornerRadius: C.cardRadius))
        .padding(.horizontal, C.pagePad)
        .onChange(of: photoSelections) { _, items in
            guard !items.isEmpty else { return }
            Task { await upload(items) }
        }
    }

    @MainActor
    private func upload(_ items: [PhotosPickerItem]) async {
        guard !isUploading else { return }
        isUploading = true
        defer {
            isUploading = false
            photoSelections = []
        }
        for item in items.prefix(max(0, 10 - photos.count)) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let prepared = AtmoV2PhotoPreparation.jpegData(data) else { continue }
                photos.append(try await model.uploadPhoto(data: prepared))
            } catch {
                model.errorMessage = "A photo could not be uploaded. Your draft was kept."
                break
            }
        }
    }

    @MainActor
    private func publish() async {
        var attachments = photos
        if let url = firstURL(in: text) {
            attachments.append(
                AtmoV2AttachmentDraft(
                    type: "LINK",
                    canonicalUrl: url.absoluteString,
                    externalUrl: url.absoluteString,
                    linkTitle: url.host ?? url.absoluteString,
                    linkDomain: url.host
                )
            )
        }
        let draft = AtmoV2PostDraft(
            body: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isSpoiler: isSpoiler,
            commentsDisabled: commentsDisabled,
            attachments: Array(attachments.prefix(10)),
            poll: validPoll
        )
        guard await model.publish(draft) else { return }
        text = ""
        photos = []
        showPoll = false
        pollQuestion = ""
        pollOptions = ["", ""]
        allowsMultiple = false
        pollResultsVisibility = "AFTER_VOTE"
        allowsVoteChanges = true
        pollHasClose = false
        pollClosesAt = Date().addingTimeInterval(86_400)
        isSpoiler = false
        commentsDisabled = false
    }

    private func firstURL(in value: String) -> URL? {
        let words = value.split(whereSeparator: \.isWhitespace)
        return words.lazy.compactMap { URL(string: String($0)) }.first {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "")
        }
    }
}

private struct AtmoV2PostCard: View {
    let post: AtmoV2Post
    let isOwner: Bool
    @ObservedObject var model: AtmoV2ProfileViewModel
    @State private var commentsExpanded = false
    @State private var spoilerRevealed = false
    @State private var energyPresented = false
    @State private var sharePresented = false
    @State private var editPresented = false
    @State private var echoPresented = false
    @State private var editBody = ""
    @State private var editSpoiler = false
    @State private var editCommentsDisabled = false
    @State private var echoQuote = ""
    @State private var pollSelection: Set<String> = []

    private var publicURL: URL? {
        guard let handle = post.author.handle else { return nil }
        var components = URLComponents(string: "\(C.baseURL)/atmo/\(C.pathSegment(handle))")
        components?.queryItems = [URLQueryItem(name: "post", value: post.id)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SocialIdentityAvatar(image: post.author.image, name: post.author.name ?? "Atmo", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.name ?? "Atmo").font(.subheadline.bold()).foregroundStyle(C.text)
                    if let handle = post.author.handle {
                        Text("@\(handle)").font(.caption).foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                if isOwner {
                    Menu {
                        Button {
                            editBody = post.body ?? ""
                            editSpoiler = post.isSpoiler
                            editCommentsDisabled = post.commentsDisabled
                            editPresented = true
                        } label: {
                            Label("Edit Ripple", systemImage: "pencil")
                        }
                        Button {
                            Task { await model.perform(.pin, on: post) }
                        } label: {
                            Label(post.pinnedAt == nil ? "Pin Ripple" : "Unpin Ripple", systemImage: "pin")
                        }
                        Button(role: .destructive) {
                            Task { await model.perform(.delete, on: post) }
                        } label: {
                            Label("Delete Ripple", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.plain).foregroundStyle(C.textMuted)
                    .accessibilityLabel("Ripple actions")
                }
            }
            if let body = post.body, !body.isEmpty {
                if post.isSpoiler && !spoilerRevealed {
                    Button("Reveal spoiler") { spoilerRevealed = true }
                        .font(.subheadline.bold()).foregroundStyle(C.watch)
                } else {
                    Text(body).font(.body).foregroundStyle(C.text)
                }
            }
            let photoURLs = post.attachments.filter { $0.type == "IMAGE" }.compactMap(\.imageUrl)
            if !photoURLs.isEmpty {
                AtmoV2PhotoGrid(urls: photoURLs)
            }
            ForEach(post.attachments.filter { $0.type == "LINK" }) { link in
                if let raw = link.externalUrl, let url = URL(string: raw) {
                    Link(destination: url) {
                        HStack(spacing: 12) {
                            if let image = link.linkImageUrl {
                                CachedRemoteImage(url: C.mediaURL(image), targetSize: CGSize(width: 96, height: 72)) {
                                    $0.resizable().scaledToFill()
                                } placeholder: { Color.clear }
                                .frame(width: 88, height: 64).clipped()
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.linkTitle ?? link.linkDomain ?? raw)
                                    .font(.subheadline.bold()).lineLimit(1)
                                if let description = link.linkDescription {
                                    Text(description).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                                }
                                Text(link.linkDomain ?? url.host ?? "")
                                    .font(.caption2).foregroundStyle(C.textTertiary)
                            }
                            Spacer()
                        }
                        .foregroundStyle(C.text)
                        .padding(10)
                        .background(C.elevated, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let echo = post.echo {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Echo", systemImage: "wave.3.right")
                        .font(.caption.bold()).foregroundStyle(C.watch)
                    if let quote = echo.quote, quote != post.body {
                        Text(quote).font(.subheadline).foregroundStyle(C.text)
                    }
                    Text(echo.sourceType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption2).foregroundStyle(C.textTertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.elevated, in: RoundedRectangle(cornerRadius: 12))
            }
            if let poll = post.poll {
                AtmoV2PollCard(
                    poll: poll,
                    selection: $pollSelection,
                    isBusy: model.isBusy("vote:\(post.id)")
                ) {
                    Task { await model.perform(.vote(Array(pollSelection)), on: post) }
                }
            }
            if let energy = post.energy, post.counts.energy > 0 {
                AtmoV2EnergyMeter(energy: energy, count: post.counts.energy)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    Button { energyPresented = true } label: {
                    Label(post.counts.energy == 0 ? "Add Energy" : "\(post.counts.energy) Energy", systemImage: "bolt")
                    }
                    Button {
                        commentsExpanded.toggle()
                        if commentsExpanded && model.commentsByPost[post.id] == nil {
                            Task { await model.loadComments(postID: post.id) }
                        }
                    } label: {
                        Label(post.counts.comments == 0 ? "Comment" : "\(post.counts.comments) Comments", systemImage: "bubble.left")
                    }
                    Button { echoPresented = true } label: {
                        Label(post.counts.echoes == 0 ? "Echo" : "\(post.counts.echoes) Echoes", systemImage: "wave.3.right")
                    }
                    Button { sharePresented = true } label: {
                        Label(post.counts.shares == 0 ? "Share" : "\(post.counts.shares) Shares", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.caption).foregroundStyle(C.textMuted)
            if commentsExpanded && !post.commentsDisabled {
                AtmoV2CommentsPanel(post: post, model: model)
            }
        }
        .padding(14)
        .background(C.surface)
        .sheet(isPresented: $energyPresented) {
            AtmoV2EnergySheet(post: post, model: model)
        }
        .sheet(isPresented: $sharePresented) {
            if let publicURL {
                AtmoV2ShareSheet(items: [publicURL]) { completed in
                    guard completed else { return }
                    Task { await model.perform(.share, on: post) }
                }
            }
        }
        .sheet(isPresented: $editPresented) {
            NavigationStack {
                Form {
                    TextField("Ripple text", text: $editBody, axis: .vertical).lineLimit(3...12)
                    Toggle("Mark as spoiler", isOn: $editSpoiler)
                    Toggle("Disable comments", isOn: $editCommentsDisabled)
                }
                .navigationTitle("Edit Ripple")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                await model.perform(
                                    .edit(
                                        body: editBody.trimmingCharacters(in: .whitespacesAndNewlines),
                                        spoiler: editSpoiler,
                                        commentsDisabled: editCommentsDisabled
                                    ),
                                    on: post
                                )
                                if !model.isBusy("edit:\(post.id)") { editPresented = false }
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $echoPresented) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Echo this Ripple to your public Atmo.")
                        .font(.subheadline).foregroundStyle(C.textMuted)
                    TextField("Add a quote (optional)", text: $echoQuote, axis: .vertical)
                        .lineLimit(3...10)
                        .padding(12)
                        .background(C.elevated, in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                }
                .padding()
                .background(C.bg)
                .navigationTitle("Echo")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { echoPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Echo") {
                            Task {
                                await model.perform(
                                    .echo(quote: echoQuote.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    on: post
                                )
                                echoPresented = false
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onAppear {
            pollSelection = Set(post.poll?.options.filter(\.selected).map(\.id) ?? [])
        }
    }

}

private struct AtmoV2ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum AtmoV2PhotoPreparation {
    static func jpegData(_ original: Data) -> Data? {
        guard let image = UIImage(data: original) else { return nil }
        let maxBytes = 3_750_000
        var maxPixel: CGFloat = 2048
        var quality: CGFloat = 0.84
        for _ in 0..<6 {
            let side = max(image.size.width, image.size.height)
            let scale = side > maxPixel ? maxPixel / side : 1
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let rendered = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
            maxPixel *= 0.82
            quality = max(0.58, quality - 0.07)
        }
        return nil
    }
}

private struct AtmoV2PhotoGrid: View {
    let urls: [String]
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: urls.count == 1 ? [GridItem(.flexible())] : columns, spacing: 4) {
            ForEach(Array(urls.prefix(10).enumerated()), id: \.offset) { _, url in
                CachedRemoteImage(url: C.mediaURL(url), targetSize: CGSize(width: 720, height: 520)) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(C.elevated)
                }
                .frame(minHeight: urls.count == 1 ? 220 : 130, maxHeight: urls.count == 1 ? 420 : 220)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(urls.count) photos")
    }
}

private struct AtmoV2PollCard: View {
    let poll: AtmoV2Poll
    @Binding var selection: Set<String>
    let isBusy: Bool
    let vote: () -> Void

    private var isClosed: Bool { poll.closedAt != nil }
    private var hasVoted: Bool { poll.options.contains(where: \.selected) }
    private var showResults: Bool {
        poll.resultsVisibility == "ALWAYS" ||
        (poll.resultsVisibility == "AFTER_VOTE" && hasVoted) ||
        (poll.resultsVisibility == "AFTER_CLOSE" && isClosed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(poll.question).font(.subheadline.bold()).foregroundStyle(C.text)
            ForEach(poll.options) { option in
                Button {
                    guard !isClosed else { return }
                    if poll.allowsMultiple {
                        if selection.contains(option.id) {
                            selection.remove(option.id)
                        } else if selection.count < poll.maxSelections {
                            selection.insert(option.id)
                        }
                    } else {
                        selection = [option.id]
                    }
                } label: {
                    ZStack(alignment: .leading) {
                        if showResults {
                            GeometryReader { proxy in
                                let total = max(poll.options.compactMap(\.voteCount).reduce(0, +), 1)
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(C.watch.opacity(0.16))
                                    .frame(width: proxy.size.width * CGFloat(option.voteCount ?? 0) / CGFloat(total))
                            }
                        }
                        HStack {
                            Image(systemName: selection.contains(option.id) ? "checkmark.circle.fill" : "circle")
                            Text(option.label)
                            Spacer()
                            if showResults, let count = option.voteCount {
                                Text("\(count)").monospacedDigit()
                            }
                        }
                        .padding(10)
                    }
                    .frame(minHeight: 42)
                    .background(C.elevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).foregroundStyle(C.text)
                .disabled(isClosed || (hasVoted && !poll.allowsVoteChanges))
                .accessibilityAddTraits(selection.contains(option.id) ? .isSelected : [])
            }
            HStack {
                if let voters = poll.totalVoters {
                    Text("\(voters) voters")
                }
                if isClosed { Text("Poll closed") }
                Spacer()
                Button(hasVoted ? "Update vote" : "Vote", action: vote)
                    .disabled(selection.isEmpty || isBusy || isClosed || (hasVoted && !poll.allowsVoteChanges))
            }
            .font(.caption).foregroundStyle(C.textMuted)
        }
        .padding(12)
        .background(C.bg.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AtmoV2EnergyMeter: View {
    let energy: AtmoV2Energy
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.0f", energy.average))
                    .font(.caption.bold().monospacedDigit())
                Text(count == 1 ? "1 Energy" : "\(count) Energy")
                    .font(.caption).foregroundStyle(C.textMuted)
                Spacer()
                ForEach(
                    energy.tags.sorted(by: { $0.value > $1.value }).prefix(3).map(\.key),
                    id: \.self
                ) { tag in
                    Label(atmoEnergyLabel(tag), systemImage: atmoEnergySymbol(tag))
                        .font(.caption2).foregroundStyle(C.textMuted)
                }
            }
            GeometryReader { proxy in
                Capsule().fill(C.borderSubtle)
                    .overlay(alignment: .leading) {
                        Capsule().fill(atmoEnergyGradient)
                            .frame(width: proxy.size.width * CGFloat(min(max(energy.average, 0), 100) / 100))
                    }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Average Energy \(Int(energy.average)) out of 100 from \(count) people")
    }
}

private struct AtmoV2EnergySheet: View {
    let post: AtmoV2Post
    @ObservedObject var model: AtmoV2ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var overall: Double
    @State private var selected: Set<String>
    private let tags = ["HITS", "INSPIRED", "REAL", "DEEP", "CHILL", "CLUTCH"]

    init(post: AtmoV2Post, model: AtmoV2ProfileViewModel) {
        self.post = post
        self.model = model
        _overall = State(initialValue: Double(post.energy?.viewer?.overall ?? 75))
        _selected = State(initialValue: Set(post.energy?.viewer?.tags ?? []))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(Int(overall)) / 100")
                    .font(.title2.bold().monospacedDigit()).foregroundStyle(C.text)
                Slider(value: $overall, in: 1...100, step: 1).tint(C.watch)
                    .accessibilityLabel("Energy intensity")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            if selected.contains(tag) { selected.remove(tag) }
                            else if selected.count < 3 { selected.insert(tag) }
                        } label: {
                            Label(atmoEnergyLabel(tag), systemImage: atmoEnergySymbol(tag))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    selected.contains(tag) ? AnyShapeStyle(atmoEnergyGradient) : AnyShapeStyle(C.elevated),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                        }
                        .buttonStyle(.plain).foregroundStyle(selected.contains(tag) ? C.bg : C.text)
                        .accessibilityAddTraits(selected.contains(tag) ? .isSelected : [])
                    }
                }
                Text("Choose up to three signals.")
                    .font(.caption).foregroundStyle(C.textMuted)
                Spacer()
                if post.energy?.viewer != nil {
                    Button("Remove Energy", role: .destructive) {
                        Task {
                            await model.perform(.energy(nil), on: post)
                            dismiss()
                        }
                    }
                }
            }
            .padding()
            .background(C.bg)
            .navigationTitle("Add Energy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.perform(
                                .energy(AtmoV2EnergyDraft(
                                    overall: Int(overall),
                                    tags: Array(selected),
                                    review: nil
                                )),
                                on: post
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AtmoV2CommentsPanel: View {
    let post: AtmoV2Post
    @ObservedObject var model: AtmoV2ProfileViewModel
    @EnvironmentObject private var auth: AuthManager
    @State private var draft = ""
    @State private var replyTo: AtmoV2Comment?
    @State private var editing: AtmoV2Comment?
    @State private var editText = ""

    private var comments: [AtmoV2Comment] { model.commentsByPost[post.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isBusy("comments:\(post.id)") && comments.isEmpty {
                ProgressView().tint(C.watch)
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(comment.author?.name ?? comment.author?.handle ?? "User")
                            .font(.caption.bold()).foregroundStyle(C.text)
                        if comment.parentId != nil {
                            Text("reply").font(.caption2).foregroundStyle(C.textTertiary)
                        }
                        Spacer()
                        Menu {
                            Button("Reply") { replyTo = comment }
                            if comment.author?.id == auth.currentUser?.id {
                                Button("Edit") {
                                    editing = comment
                                    editText = comment.content
                                }
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteComment(comment) }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                    Text(comment.content).font(.subheadline).foregroundStyle(C.text)
                    Button {
                        Task { await model.toggleCommentLike(comment) }
                    } label: {
                        Label(
                            comment.likeCount == 0 ? "Like" : "\(comment.likeCount)",
                            systemImage: comment.likedByViewer ? "heart.fill" : "heart"
                        )
                    }
                    .font(.caption2).foregroundStyle(comment.likedByViewer ? C.watch : C.textMuted)
                }
                .padding(.leading, comment.parentId == nil ? 0 : 22)
            }
            if model.commentCursorByPost[post.id] != nil {
                Button("Load more comments") {
                    Task { await model.loadComments(postID: post.id, append: true) }
                }
                .font(.caption)
            }
            if let replyTo {
                HStack {
                    Text("Replying to @\(replyTo.author?.handle ?? "user")")
                        .font(.caption).foregroundStyle(C.textMuted)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }.font(.caption)
                }
            }
            HStack {
                TextField("Write a comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...4).foregroundStyle(C.text)
                Button("Send") {
                    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if await model.addComment(post: post, content: value, parentID: replyTo?.id) {
                            draft = ""
                            replyTo = nil
                        }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10).background(C.elevated, in: RoundedRectangle(cornerRadius: 10))
        }
        .sheet(item: $editing) { comment in
            NavigationStack {
                Form { TextField("Comment", text: $editText, axis: .vertical).lineLimit(3...10) }
                    .navigationTitle("Edit Comment")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                Task {
                                    await model.editComment(comment, content: editText)
                                    editing = nil
                                }
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }
}

private let atmoEnergyGradient = LinearGradient(
    colors: [
        Color(hex: "#6AE383"), Color(hex: "#B7E875"), Color(hex: "#F2D36B"),
        Color(hex: "#E8A15F"), Color(hex: "#A780D7"), Color(hex: "#5967C9")
    ],
    startPoint: .leading,
    endPoint: .trailing
)

private func atmoEnergyLabel(_ value: String) -> String {
    switch value.uppercased() {
    case "HITS": "Hits"
    case "INSPIRED": "Inspired"
    case "REAL": "Real"
    case "DEEP": "Deep"
    case "CHILL": "Chill"
    case "CLUTCH": "Clutch"
    default: value.capitalized
    }
}

private func atmoEnergySymbol(_ value: String) -> String {
    switch value.uppercased() {
    case "HITS": "waveform.path"
    case "INSPIRED": "star.fill"
    case "REAL": "lightbulb.fill"
    case "DEEP": "brain.head.profile"
    case "CHILL": "face.smiling"
    case "CLUTCH": "bolt.fill"
    default: "sparkles"
    }
}

private struct VibeHero: View {
    let detail: VibeDetailResponse
    let isBusy: Bool
    let relationshipAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedRemoteImage(
                url: C.mediaURL(detail.club.bannerURL),
                targetSize: CGSize(width: UIScreen.main.bounds.width, height: 160)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [C.watch.opacity(0.28), C.elevated],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .frame(height: 160)
            .clipped()

            HStack(alignment: .top, spacing: 12) {
                SocialIdentityAvatar(
                    image: detail.club.avatarURL,
                    name: detail.club.name,
                    size: 76
                )
                .offset(y: -26)

                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.club.name).font(.title2.bold()).foregroundStyle(C.text)
                    if let description = detail.club.description, !description.isEmpty {
                        Text(description).font(.subheadline).foregroundStyle(C.textMuted).lineLimit(3)
                    }
                    HStack(spacing: 12) {
                        if detail.club.followerCount > 0 {
                            Text("\(detail.club.followerCount) followers")
                        }
                        if detail.club.postCount > 0 {
                            Text("\(detail.club.postCount) Ripples")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                }
                Spacer()
                if let relationshipAction {
                    Button(action: relationshipAction) {
                        if isBusy {
                            ProgressView().tint(.black)
                        } else {
                            Text(relationshipLabel)
                        }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .disabled(isBusy)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.bottom, 4)
        }
        .background(C.surface)
    }

    private var relationshipLabel: String {
        if detail.club.isPersonal {
            return detail.following ? "Following" : "Follow"
        }
        if detail.capabilities.canLeave,
           detail.membership?.role.uppercased() != "OWNER" {
            return "Leave"
        }
        if detail.capabilities.canRequestJoin {
            return "Request to Join"
        }
        return "Join"
    }
}

private struct SocialUnavailable: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "person.2.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
        }
        .foregroundStyle(C.text)
        .padding(.top, 60)
    }
}

func socialErrorMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription
        ?? "The social experience could not be loaded."
}
