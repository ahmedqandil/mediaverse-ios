import AVKit
import SwiftUI

struct VibeDetailView: View {
    fileprivate enum VibeSheet: String, Identifiable {
        case options
        case affiliations
        case moderation
        case invitations
        case settings
        case composer

        var id: String { rawValue }
    }

    let slug: String
    var initialWaveSlug: String? = nil
    var initialManagementTab: String? = nil
    @State private var detail: VibeDetailResponse?
    @State private var ripples: [Ripple] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var isMutatingRelationship = false
    @State private var relationshipNotice: String?
    @State private var errorMessage: String?
    @State private var activeSheet: VibeSheet?
    @StateObject private var autoplay = SocialFeedAutoplayController()
    @AppStorage("playerMuted") private var playerMuted = false
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let features = SocialFeatureConfiguration.runtime()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let detail {
                    VibeHero(
                        detail: detail,
                        isBusy: isMutatingRelationship,
                        relationshipAction: relationshipAction
                    )
                    if let relationshipNotice {
                        Text(relationshipNotice)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(C.watch)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, C.pagePad)
                    }
                    if features.rippleComposerEnabled && detail.capabilities.canPost {
                        rippleComposerPrompt(for: detail)
                            .padding(.horizontal, C.pagePad)
                    }
                    if !detail.club.isPersonal {
                        VibeEventVibeSection(
                            vibeSlug: detail.club.slug,
                            canManage: detail.capabilities.canManageClub
                        )
                    }
                    ForEach(ripples) {
                        RippleCard(
                            ripple: $0,
                            actions: RippleCardActions(
                                togglePin: detail.capabilities.canModerateContent
                                    ? vibePinAction(for: $0)
                                    : nil,
                                isPinned: $0.pinnedAt != nil,
                                pinTarget: "Vibe"
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
                        .padding(.horizontal, horizontalSizeClass == .compact ? 0 : C.pagePad)
                    }
                    if nextCursor != nil {
                        ProgressView()
                            .tint(C.watch)
                            .task { await loadMore() }
                            .padding()
                    }
                } else if isLoading {
                    ProgressView().tint(C.watch).padding(.top, 80)
                } else {
                    SocialUnavailable(
                        title: "Vibe unavailable",
                        message: errorMessage ?? "This Vibe could not be opened.",
                        retry: { Task { await load() } }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, C.bottomMenuClearance)
        }
        .coordinateSpace(name: "homeFeedScroll")
        .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
            autoplay.update(frames: frames, ripples: ripples, blocked: isAutoplayBlocked)
        }
        .onChange(of: isAutoplayBlocked) { _, blocked in
            autoplay.setBlocked(blocked, ripples: ripples)
        }
        .onDisappear { autoplay.stop() }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(detail?.club.name ?? "Vibe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasVibeOptions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .options
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Vibe options")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .options:
                if let detail {
                    VibeOptionsSheet(capabilities: detail.capabilities) { destination in
                        transitionFromOptions(to: destination)
                    }
                    .presentationDetents([.height(optionsSheetHeight(for: detail.capabilities))])
                    .presentationDragIndicator(.visible)
                }
            case .affiliations:
                VibeAffiliationsView(slug: slug)
            case .moderation:
                if let capabilities = detail?.capabilities {
                    VibeModerationView(
                        slug: slug,
                        capabilities: capabilities,
                        initialTab: initialManagementTab
                    )
                }
            case .invitations:
                if let detail {
                    VibeInvitationsView(
                        slug: slug,
                        capabilities: detail.capabilities,
                        currentRole: detail.membership?.role
                    )
                }
            case .settings:
                if let detail {
                    VibeSettingsView(detail: detail) { updatedClub in
                        self.detail = VibeDetailResponse(
                            club: updatedClub,
                            capabilities: detail.capabilities,
                            membership: detail.membership,
                            following: detail.following
                        )
                    }
                }
            case .composer:
                if let detail {
                    NavigationStack {
                        ScrollView {
                            RippleComposer(
                                destination: .vibe(
                                    slug: detail.club.slug,
                                    name: detail.club.name
                                )
                            ) { ripple in
                                ripples.insert(ripple, at: 0)
                                activeSheet = nil
                            }
                            .padding(C.pagePad)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .background(C.bg.ignoresSafeArea())
                        .navigationTitle("Create Ripple")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    activeSheet = nil
                                }
                                .foregroundStyle(C.text)
                            }
                        }
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .task(id: slug) { await load() }
        .refreshable { await load() }
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

    private func rippleComposerPrompt(for detail: VibeDetailResponse) -> some View {
        Button {
            C.lightHaptic()
            activeSheet = .composer
        } label: {
            HStack(spacing: 10) {
                SocialIdentityAvatar(
                    image: auth.currentUser?.image,
                    name: auth.currentUser?.name,
                    size: 38
                )
                Text("Create a Ripple in \(detail.club.name)…")
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                Image(systemName: "wave.3.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.watch)
            }
            .padding(12)
            .background(C.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(C.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a Ripple in \(detail.club.name)")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let loadedDetail = api.vibe(slug: slug)
            async let loadedPage = api.vibeRipples(slug: slug)
            let (detail, page) = try await (loadedDetail, loadedPage)
            self.detail = detail
            ripples = page.posts
            nextCursor = page.nextCursor
            switch initialManagementTab?.lowercased() {
            case "affiliations":
                if detail.capabilities.canManageAffiliations { activeSheet = .affiliations }
            case "requests":
                if detail.capabilities.canModerateMembers { activeSheet = .moderation }
            case "invitations", "invites":
                if detail.capabilities.canInvite { activeSheet = .invitations }
            case "settings":
                if detail.capabilities.canManageClub { activeSheet = .settings }
            default:
                break
            }
        } catch {
            detail = nil
            ripples = []
            nextCursor = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await api.vibeRipples(slug: slug, cursor: cursor)
            let existing = Set(ripples.map(\.id))
            ripples.append(contentsOf: page.posts.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func vibePinAction(for ripple: Ripple) -> () -> Void {
        {
            Task {
                do {
                    _ = try await api.setRipplePinned(
                        postId: ripple.id,
                        pinned: ripple.pinnedAt == nil
                    )
                    await load()
                } catch {
                    errorMessage = socialErrorMessage(error)
                }
            }
        }
    }

    private var relationshipAction: (() -> Void)? {
        guard let detail else { return nil }
        let canMutate = detail.club.isPersonal
            ? detail.capabilities.canFollow || detail.following
            : detail.capabilities.canJoin
                || detail.capabilities.canRequestJoin
                || (detail.capabilities.canLeave
                    && detail.membership?.role.uppercased() != "OWNER")
        guard canMutate else { return nil }
        return { Task { await mutateRelationship() } }
    }

    @MainActor
    private func mutateRelationship() async {
        guard let detail, !isMutatingRelationship else { return }
        isMutatingRelationship = true
        relationshipNotice = nil
        do {
            if detail.club.isPersonal {
                if detail.following {
                    _ = try await api.unfollowVibe(slug: slug)
                    relationshipNotice = "Vibe unfollowed."
                } else {
                    _ = try await api.followVibe(slug: slug)
                    relationshipNotice = "Vibe followed."
                }
            } else if detail.capabilities.canLeave,
                      detail.membership?.role.uppercased() != "OWNER" {
                try await api.leaveVibe(slug: slug)
                relationshipNotice = "You left this Vibe."
            } else {
                let result = try await api.joinVibe(slug: slug)
                relationshipNotice = result.pending
                    ? "Your request was sent to the Vibe moderators."
                    : "You joined this Vibe."
            }
            self.detail = try await api.vibe(slug: slug)
        } catch {
            relationshipNotice = socialErrorMessage(error)
        }
        isMutatingRelationship = false
    }

    private var hasVibeOptions: Bool {
        guard let capabilities = detail?.capabilities else { return false }
        return capabilities.canManageClub
            || capabilities.canInvite
            || capabilities.canModerateContent
            || capabilities.canModerateMembers
            || capabilities.canManageAffiliations
    }

    private func optionsSheetHeight(for capabilities: VibeCapabilities) -> CGFloat {
        var count = 0
        if capabilities.canManageClub { count += 1 }
        if capabilities.canInvite { count += 1 }
        if capabilities.canModerateContent || capabilities.canModerateMembers { count += 1 }
        if capabilities.canManageAffiliations { count += 1 }
        return CGFloat(92 + count * 58)
    }

    private func transitionFromOptions(to destination: VibeSheet) {
        activeSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            activeSheet = destination
        }
    }
}

private struct VibeOptionsSheet: View {
    let capabilities: VibeCapabilities
    let onSelect: (VibeDetailView.VibeSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vibe options")
                .font(.title3.bold())
                .foregroundStyle(C.text)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            if capabilities.canManageClub {
                option("Settings", detail: "Branding, privacy, posting, and membership", icon: "gearshape", destination: .settings)
            }
            if capabilities.canInvite {
                option("Invitations", detail: "Create and manage invitation links", icon: "person.badge.plus", destination: .invitations)
            }
            if capabilities.canModerateContent || capabilities.canModerateMembers {
                option("Moderation", detail: "Review content, requests, and members", icon: "checkmark.shield", destination: .moderation)
            }
            if capabilities.canManageAffiliations {
                option("Affiliations", detail: "Connect this Vibe to Shows and Channels", icon: "link", destination: .affiliations)
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 8)
        .background(C.bg.ignoresSafeArea())
    }

    private func option(
        _ title: String,
        detail: String,
        icon: String,
        destination: VibeDetailView.VibeSheet
    ) -> some View {
        Button {
            onSelect(destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .frame(width: 34, height: 34)
                    .background(C.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(C.textTertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
        }
        .buttonStyle(.plain)
    }
}

struct RippleDetailView: View {
    let postId: String
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("playerMuted") private var playerMuted = false
    @StateObject private var autoplay = SocialFeedAutoplayController()
    @State private var ripple: Ripple?
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let features = SocialFeatureConfiguration.runtime()

    var body: some View {
        ScrollView {
            Group {
                if let ripple {
                    RippleCard(
                        ripple: ripple,
                        allowsEngagement: features.rippleEngagementEnabled,
                        activePreviewVideoId: $autoplay.activeVideoID,
                        previewManager: autoplay.previewManager,
                        isAutoplayBlocked: isAutoplayBlocked,
                        isPreservingPreviewHandoff: autoplay.isPreservingHandoff,
                        onPreviewPaused: { videoID in
                            autoplay.suppressAndReselect(
                                videoID: videoID,
                                ripples: [ripple],
                                blocked: isAutoplayBlocked
                            )
                        },
                        onVideoHandoff: handoffToWatch
                    )
                } else if isLoading {
                    ProgressView().tint(C.watch).padding(.top, 80)
                } else {
                    SocialUnavailable(
                        title: "Ripple unavailable",
                        message: errorMessage ?? "This Ripple could not be opened.",
                        retry: { Task { await load() } }
                    )
                }
            }
            .padding(.vertical, C.pagePad)
            .padding(.horizontal, horizontalSizeClass == .compact ? 0 : C.pagePad)
        }
        .coordinateSpace(name: "homeFeedScroll")
        .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
            autoplay.update(
                frames: frames,
                ripples: ripple.map { [$0] } ?? [],
                blocked: isAutoplayBlocked
            )
        }
        .onChange(of: isAutoplayBlocked) { _, blocked in
            autoplay.setBlocked(blocked, ripples: ripple.map { [$0] } ?? [])
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Ripple")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: postId) { await load() }
        .refreshable { await load() }
        .onDisappear { autoplay.stop() }
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

    private func load() async {
        isLoading = true
        do {
            ripple = try await api.ripple(postId: postId)
            errorMessage = nil
        } catch {
            ripple = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }
}

struct AtmoProfileView: View {
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
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                ProfileView(isRootActive: isRootActive)
            } else if let handle, !handle.isEmpty {
                AtmoProfileView(handle: handle)
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
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        do {
            let response = try await APIClient.shared.fetchProfile()
            handle = response.profile.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = handle?.isEmpty == false ? nil : "Add a handle in Account to activate your public Atmo."
        } catch {
            handle = nil
            errorMessage = "Your Atmo could not be loaded. Please try again."
        }
        isLoading = false
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
