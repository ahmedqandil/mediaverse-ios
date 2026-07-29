import AVKit
import SwiftUI

struct VibeDetailView: View {
    private struct CachedWaveFeed {
        var ripples: [Ripple]
        var nextCursor: String?
        var resourceCategories: [String] = []
    }

    private struct WaveDirectoryPreview {
        let text: String?
        let lastActivityAt: String?
        let unreadCount: Int
    }

    fileprivate enum VibeSheet: String, Identifiable {
        case options
        case affiliations
        case moderation
        case invitations
        case waves
        case rules
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
    @State private var waves: [VibeWave] = []
    @State private var selectedWaveSlug: String?
    @State private var showsCommunityHomeConversation = false
    @State private var waveDirectoryPreviews: [String: WaveDirectoryPreview] = [:]
    @State private var waveSearchQuery = ""
    @AppStorage("recentVibeWaveSlugs") private var recentWaveSlugsStorage = ""
    @State private var resourceCategories: [String] = []
    @State private var selectedResourceCategory: String?
    @State private var bookmarkedResourcesOnly = false
    @State private var waveFeeds: [String: CachedWaveFeed] = [:]
    @State private var feedRequestID = UUID()
    @State private var isSwitchingWave = false
    @State private var isLoading = true
    @State private var isMutatingRelationship = false
    @State private var relationshipNotice: String?
    @State private var errorMessage: String?
    @State private var activeSheet: VibeSheet?
    @State private var showsWaveDirectory = false
    @State private var chatDraft = ""
    @State private var isSendingChatRipple = false
    @State private var pendingChatRipples: [PendingWaveRipple] = []
    @State private var matrixConnectionState: MatrixSyncConnectionState = .disabled
    @State private var matrixActivity = MatrixWaveActivity()
    @State private var waveSummaries: [WaveConversationSummary] = []
    @StateObject private var autoplay = SocialFeedAutoplayController()
    @AppStorage("playerMuted") private var playerMuted = false
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var miniPlayer: MiniPlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let matrixClient = MatrixWaveClient(sessionBroker: APIClient.shared)
    private let features = SocialFeatureConfiguration.runtime()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: isCommunityConversation ? 3 : 12) {
                if let detail {
                    if !isCommunityConversation {
                        VibeHero(
                            detail: detail,
                            isBusy: isMutatingRelationship,
                            relationshipAction: relationshipAction
                        )
                    }
                    if let relationshipNotice {
                        Text(relationshipNotice)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(C.watch)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, C.pagePad)
                    }
                    if isCommunityDirectory {
                        mobileWaveDirectory(for: detail)
                            .padding(.horizontal, C.pagePad)
                    }
                    if !isCommunityDirectory,
                       !detail.club.isPersonal,
                       !waves.isEmpty,
                       horizontalSizeClass != .compact {
                        waveConversationHeader
                            .padding(.horizontal, C.pagePad)
                        waveContextCard
                            .padding(.horizontal, C.pagePad)
                    }
                    if isCommunityConversation {
                        mobileWaveConversationHeader(for: detail)
                            .padding(.horizontal, C.pagePad)
                        if matrixRealtimeEnabled {
                            waveRealtimeStatus
                                .padding(.horizontal, C.pagePad)
                        }
                    }
                    if !waveSummaries.isEmpty {
                        waveSummaryCard
                            .padding(.horizontal, C.pagePad)
                    }
                    if !isCommunityDirectory, selectedWave?.type == .resources {
                        resourceFilters
                    }
                    if !isCommunityDirectory,
                       features.rippleComposerEnabled,
                       canPost(in: detail),
                       !isCommunityConversation {
                        rippleComposerPrompt(for: detail)
                            .padding(.horizontal, C.pagePad)
                    }
                    if !isCommunityDirectory,
                       !detail.club.isPersonal,
                       showsEventsSection {
                        VibeEventVibeSection(
                            vibeSlug: detail.club.slug,
                            canManage: selectedWave?.capabilities.canCreateEvent
                                ?? detail.capabilities.canManageClub,
                            waveID: selectedWave?.type == .events ? selectedWave?.id : nil
                        )
                    }
                    if !isCommunityDirectory, isSwitchingWave {
                        ProgressView()
                            .tint(C.watch)
                            .padding(.vertical, 28)
                    }
                    if !isCommunityDirectory {
                    ForEach(pendingChatRipples) { pending in
                        pendingRippleRow(pending)
                            .padding(.horizontal, horizontalSizeClass == .compact ? 0 : C.pagePad)
                    }
                    ForEach(Array(ripples.enumerated()), id: \.element.id) { index, ripple in
                        RippleCard(
                            ripple: ripple,
                            actions: RippleCardActions(
                                togglePin: detail.capabilities.canModerateContent
                                    ? vibePinAction(for: ripple)
                                    : nil,
                                isPinned: ripple.pinnedAt != nil,
                                pinTarget: "Vibe",
                                canManageQuestionAnswers: detail.capabilities.canModerateContent
                            ),
                            allowsEngagement: features.rippleEngagementEnabled,
                            presentation: detail.club.isPersonal ? .social : .waveConversation,
                            isGroupedWithPrevious: isWaveMessageGrouped(
                                ripple,
                                after: index > 0 ? ripples[index - 1] : nil
                            ),
                            isLastInMessageGroup: !isWaveMessageGrouped(
                                index + 1 < ripples.count ? ripples[index + 1] : nil,
                                after: ripple
                            ),
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
                    }
                    if !isCommunityDirectory, nextCursor != nil {
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
            .padding(.bottom, isCommunityConversation ? 0 : 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let detail,
               isCommunityConversation,
               features.rippleComposerEnabled,
               canPost(in: detail) {
                waveChatComposerEntry(for: detail)
            }
        }
        .coordinateSpace(name: "homeFeedScroll")
        .onPreferenceChange(HomeVideoFramePreferenceKey.self) { frames in
            autoplay.update(frames: frames, ripples: ripples, blocked: isAutoplayBlocked)
        }
        .onChange(of: isAutoplayBlocked) { _, blocked in
            autoplay.setBlocked(blocked, ripples: ripples)
        }
        .onDisappear {
            autoplay.stop()
            Task { await matrixClient.disconnect() }
        }
        .task(id: matrixTaskIdentity) {
            await runMatrixRealtime()
        }
        .onChange(of: chatDraft) { _, draft in
            updateMatrixTyping(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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
            case .waves:
                VibeWavesManagementView(vibeSlug: slug) {
                    Task { await load() }
                }
            case .rules:
                VibeRulesView(vibeSlug: slug)
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
                                destination: composerDestination(for: detail)
                            ) { ripple in
                                ripples.insert(ripple, at: 0)
                                cacheCurrentFeed()
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
        .sheet(isPresented: $showsWaveDirectory) {
            NavigationStack {
                List {
                    Section("Conversation spaces") {
                        waveDirectoryRow(
                            title: "Vibe Home",
                            detail: "Everything happening across \(detail?.club.name ?? "this Vibe")",
                            slug: nil,
                            systemImage: "house"
                        )
                        ForEach(waves) { wave in
                            waveDirectoryRow(
                                title: wave.name,
                                detail: waveDirectoryDetail(wave),
                                slug: wave.slug,
                                systemImage: waveSystemImage(wave),
                                count: wave._count?.posts ?? 0
                            )
                        }
                    }
                    Section("Vibe information") {
                        Button {
                            showsWaveDirectory = false
                            activeSheet = .rules
                        } label: {
                            Label("Rules", systemImage: "list.bullet.clipboard")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(C.bg)
                .navigationTitle("Waves")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsWaveDirectory = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                Text(composerPrompt(for: detail))
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
        .accessibilityLabel(composerPrompt(for: detail))
    }

    private func waveChatComposerEntry(for detail: VibeDetailResponse) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                C.lightHaptic()
                activeSheet = .composer
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(C.text)
                    .frame(width: 42, height: 42)
                    .background(C.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add photos, poll, or attachment")

            TextField(
                "Message \(selectedWave?.name ?? detail.club.name)",
                text: $chatDraft,
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(C.text)
            .lineLimit(1...5)
            .submitLabel(.send)
            .onSubmit {
                Task { await sendChatRipple(in: detail) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 42)
            .background(C.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                Task { await sendChatRipple(in: detail) }
            } label: {
                Group {
                    if isSendingChatRipple {
                        ProgressView().tint(C.bg)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(C.bg)
                .frame(width: 42, height: 42)
                .background(canSendChatRipple ? C.watch : C.textTertiary)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSendChatRipple)
            .accessibilityLabel("Send Ripple")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(C.borderSubtle).frame(height: 1)
        }
        .accessibilityIdentifier("wave.composer.dock")
    }

    private var canSendChatRipple: Bool {
        !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSendingChatRipple
    }

    @MainActor
    private func sendChatRipple(in detail: VibeDetailResponse) async {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingChatRipple else { return }
        let pending = PendingWaveRipple(
            vibeSlug: detail.club.slug,
            waveId: selectedWave?.id,
            body: text
        )
        pendingChatRipples.append(pending)
        chatDraft = ""
        isSendingChatRipple = true
        errorMessage = nil
        await sendPendingRipple(pending, in: detail)
        isSendingChatRipple = false
    }

    @MainActor
    private func sendPendingRipple(_ pending: PendingWaveRipple, in detail: VibeDetailResponse) async {
        guard let index = pendingChatRipples.firstIndex(where: { $0.id == pending.id }) else {
            return
        }
        pendingChatRipples[index].state = pendingChatRipples[index].attemptCount > 0
            ? .retrying
            : .sending
        pendingChatRipples[index].attemptCount += 1
        pendingChatRipples[index].lastError = nil
        do {
            let created = try await api.createRipple(
                inVibe: detail.club.slug,
                body: pending.body,
                attachments: [],
                waveId: pending.waveId,
                clientRequestId: pending.idempotencyKey
            )
            pendingChatRipples.removeAll { $0.id == pending.id }
            if created.status == "PENDING_REVIEW" {
                relationshipNotice = "Ripple submitted for moderator review."
            } else {
                ripples.insert(created, at: 0)
                cacheCurrentFeed()
            }
        } catch {
            if let failedIndex = pendingChatRipples.firstIndex(where: { $0.id == pending.id }) {
                pendingChatRipples[failedIndex].state = .failed
                pendingChatRipples[failedIndex].lastError = "Not sent"
            }
            errorMessage = socialErrorMessage(error)
        }
    }

    private var matrixRealtimeEnabled: Bool {
        guard let wave = selectedWave else { return false }
        return SocialRealtimeRollout.waveRealtimeEnabled(
            local: features,
            server: wave.realtimeCapabilities,
            binding: wave.matrixBinding
        )
    }

    private var matrixTaskIdentity: String {
        guard matrixRealtimeEnabled, let wave = selectedWave else { return "legacy" }
        return "\(wave.id):\(wave.matrixBinding?.roomId ?? "")"
    }

    private var waveSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Conversation summary", systemImage: "text.quote")
                .font(.subheadline.bold())
                .foregroundStyle(C.text)
            ForEach(waveSummaries.prefix(1)) { summary in
                Text(summary.content)
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
                if !summary.citations.isEmpty {
                    Text("\(summary.citations.count) verified Ripple citation\(summary.citations.count == 1 ? "" : "s")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(C.watch)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
    }

    @MainActor
    private func loadWaveSummaries(_ waveSlug: String?) async {
        waveSummaries = []
        guard let waveSlug, matrixRealtimeEnabled else { return }
        // The server returns an empty list when Phase 2, platform visibility,
        // citation safety, or access checks fail. Never synthesize a digest.
        waveSummaries = (try? await api.waveSummaries(
            vibeSlug: slug,
            waveSlug: waveSlug
        ).summaries) ?? []
    }

    @MainActor
    private func runMatrixRealtime() async {
        guard
            matrixRealtimeEnabled,
            let roomId = selectedWave?.matrixBinding?.roomId
        else {
            matrixConnectionState = .disabled
            matrixActivity = MatrixWaveActivity()
            await matrixClient.disconnect()
            return
        }
        matrixConnectionState = .connecting
        do {
            try await matrixClient.connect()
            matrixConnectionState = .connected
            while !Task.isCancelled {
                let activity = try await matrixClient.sync(roomId: roomId)
                guard !Task.isCancelled else { return }
                matrixActivity = activity
                if !isLoading, let eventId = activity.latestEventId {
                    try? await matrixClient.markRead(roomId: roomId, eventId: eventId)
                    matrixActivity.unreadCount = 0
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // Realtime degradation never takes down the legacy Wave feed.
            matrixConnectionState = .degraded
        }
    }

    private func updateMatrixTyping(_ isTyping: Bool) {
        guard
            matrixRealtimeEnabled,
            let roomId = selectedWave?.matrixBinding?.roomId
        else { return }
        Task {
            try? await matrixClient.setTyping(isTyping, roomId: roomId)
        }
    }

    private var waveRealtimeStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(matrixConnectionState == .connected ? C.watch : C.textTertiary)
                .frame(width: 7, height: 7)
            if !matrixActivity.typingUserIds.isEmpty {
                Text(matrixActivity.typingUserIds.count == 1
                    ? "Someone is typing…"
                    : "\(matrixActivity.typingUserIds.count) people are typing…")
            } else if matrixConnectionState == .degraded {
                Text("Live updates paused")
            } else {
                Text("Live Wave")
            }
            Spacer()
            if matrixActivity.unreadCount > 0 {
                Text("\(matrixActivity.unreadCount) unread")
                    .fontWeight(.semibold)
            }
        }
        .font(.caption)
        .foregroundStyle(C.textMuted)
        .accessibilityElement(children: .combine)
    }

    private func pendingRippleRow(_ pending: PendingWaveRipple) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(pending.body)
                .font(.body)
                .foregroundStyle(C.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: pending.state == .failed ? "exclamationmark.circle" : "clock")
                Text(pending.state == .failed ? "Not sent" : "Sending…")
                Spacer()
                if pending.state == .failed, let detail {
                    Button("Retry") {
                        Task { await sendPendingRipple(pending, in: detail) }
                    }
                    .fontWeight(.semibold)
                    Button("Remove") {
                        pendingChatRipples.removeAll { $0.id == pending.id }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(pending.state == .failed ? Color.red : C.textMuted)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .background(C.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pending.body), \(pending.state.rawValue.lowercased())")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let detail = try await api.vibe(slug: slug)
            async let loadedPage = api.vibeRipples(slug: slug)
            async let loadedWaves = detail.club.isPersonal ? [] : api.vibeWaves(slug: slug)
            let (page, availableWaves) = try await (loadedPage, loadedWaves)
            self.detail = detail
            waves = availableWaves.filter { $0.archivedAt == nil && $0.capabilities.canView }
            selectedWaveSlug = waves.contains(where: { $0.slug == initialWaveSlug })
                ? initialWaveSlug
                : nil
            showsCommunityHomeConversation = false
            ripples = page.posts
            nextCursor = page.nextCursor
            resourceCategories = page.resourceCategories
            waveFeeds = [feedKey(nil): CachedWaveFeed(
                ripples: page.posts,
                nextCursor: page.nextCursor,
                resourceCategories: page.resourceCategories
            )]
            if selectedWaveSlug != nil {
                await switchWave(to: selectedWaveSlug)
            }
            Task { await loadWaveDirectoryPreviews(for: waves) }
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
            waves = []
            selectedWaveSlug = nil
            showsCommunityHomeConversation = false
            waveDirectoryPreviews = [:]
            waveFeeds = [:]
            ripples = []
            nextCursor = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        let requestID = feedRequestID
        let waveSlug = selectedWaveSlug
        do {
            let page = try await api.vibeRipples(
                slug: slug,
                cursor: cursor,
                wave: waveSlug,
                resourceCategory: selectedResourceCategory,
                bookmarkedOnly: bookmarkedResourcesOnly
            )
            guard requestID == feedRequestID, waveSlug == selectedWaveSlug else { return }
            let existing = Set(ripples.map(\.id))
            ripples.append(contentsOf: page.posts.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
            cacheCurrentFeed()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private var vibePresentation: VibeDestinationPresentation {
        VibeDestinationPresentation.resolve(
            isPersonal: detail?.club.isPersonal ?? true,
            selectedWaveSlug: selectedWaveSlug,
            showsHomeConversation: showsCommunityHomeConversation
        )
    }

    private var isCommunityDirectory: Bool {
        vibePresentation == .waveDirectory
    }

    private var isCommunityConversation: Bool {
        vibePresentation == .waveConversation
    }

    private func mobileWaveDirectory(for detail: VibeDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("WAVES")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(C.watch)
                Text("Choose a conversation")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(C.text)
                Text("See what is active, catch up on unread replies, or browse everything happening in \(detail.club.name).")
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
            }

            TextField("Search Waves", text: $waveSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(C.elevated)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if waveSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !recentWaves.isEmpty {
                    Section("Recently visited") {
                        ForEach(recentWaves) { wave in
                            mobileWaveRow(for: wave)
                        }
                    }
                }

                if !unreadWaves.isEmpty {
                    Section("Unread") {
                        ForEach(unreadWaves) { wave in
                            mobileWaveRow(for: wave)
                        }
                    }
                }
            }

            Section("All Waves") {
                if filteredDirectoryWaves.count == waves.count {
                    mobileWaveDirectoryRow(
                        title: "Vibe Home",
                        description: "Everything happening across \(detail.club.name)",
                        systemImage: "house.fill",
                        count: detail.club.postCount,
                        preview: homeDirectoryPreview
                    ) {
                        showsCommunityHomeConversation = true
                        Task { await switchWave(to: nil) }
                    }
                }

                ForEach(filteredDirectoryWaves) { wave in
                    mobileWaveRow(for: wave)
                }
            }

            if filteredDirectoryWaves.isEmpty {
                Text("No Waves match your search.")
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            Button {
                activeSheet = .rules
            } label: {
                Label("Vibe rules", systemImage: "list.bullet.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(C.elevated.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(detail.club.name) Wave directory")
    }

    private func mobileWaveRow(for wave: VibeWave) -> some View {
        mobileWaveDirectoryRow(
            title: wave.name,
            description: waveDirectoryRichDetail(wave),
            systemImage: waveSystemImage(wave),
            count: wave.activeConversationCount > 0
                ? wave.activeConversationCount
                : wave._count?.posts ?? 0,
            preview: directoryPreview(for: wave),
            specializedLabel: waveTypeLabel(wave.type)
        ) {
            rememberVisitedWave(wave.slug)
            Task { await openDedicatedWave(wave.slug) }
        }
    }

    private var filteredDirectoryWaves: [VibeWave] {
        let query = waveSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return waves }
        return waves.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
                || waveTypeLabel($0.type).localizedCaseInsensitiveContains(query)
        }
    }

    private var recentWaves: [VibeWave] {
        recentWaveSlugs.compactMap { slug in waves.first { $0.slug == slug } }
    }

    private var unreadWaves: [VibeWave] {
        waves.filter { directoryPreview(for: $0)?.unreadCount ?? 0 > 0 }
    }

    private var recentWaveSlugs: [String] {
        let vibePrefix = "\(slug)::"
        return recentWaveSlugsStorage
            .split(separator: "|")
            .map(String.init)
            .filter { $0.hasPrefix(vibePrefix) }
            .map { String($0.dropFirst(vibePrefix.count)) }
    }

    private func rememberVisitedWave(_ waveSlug: String) {
        let scopedSlug = "\(slug)::\(waveSlug)"
        let stored = recentWaveSlugsStorage.split(separator: "|").map(String.init)
        let otherVibes = stored.filter { !$0.hasPrefix("\(slug)::") }
        let currentVibe = ([scopedSlug] + recentWaveSlugs
            .filter { $0 != waveSlug }
            .map { "\(slug)::\($0)" })
            .prefix(5)
        recentWaveSlugsStorage = (Array(currentVibe) + otherVibes)
            .joined(separator: "|")
    }

    private func directoryPreview(for wave: VibeWave) -> WaveDirectoryPreview? {
        let loaded = waveDirectoryPreviews[wave.slug]
        let safeParticipant = wave.lastParticipant?.name
            ?? wave.lastParticipant?.handle.map { "@\($0)" }
        return WaveDirectoryPreview(
            text: wave.directoryPreview
                ?? safeParticipant.map { "\($0) was active" }
                ?? loaded?.text,
            lastActivityAt: wave.lastActivityAt ?? loaded?.lastActivityAt,
            unreadCount: max(wave.unreadCount, loaded?.unreadCount ?? 0)
        )
    }

    private func waveDirectoryRichDetail(_ wave: VibeWave) -> String {
        var context = [wave.visibility.capitalized]
        if wave.requiresPostApproval {
            context.append("Approval required")
        }
        let description = waveDirectoryDetail(wave)
        if context.isEmpty { return description }
        return "\(description) · \(context.joined(separator: " · "))"
    }

    private func mobileWaveDirectoryRow(
        title: String,
        description: String,
        systemImage: String,
        count: Int,
        preview: WaveDirectoryPreview?,
        specializedLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(C.watch)
                    .frame(width: 38, height: 38)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)
                        if let specializedLabel, specializedLabel != "General", specializedLabel != "Custom" {
                            Text(specializedLabel)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(C.watch)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(C.watch.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                    if let text = preview?.text, !text.isEmpty {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(C.text.opacity(0.76))
                            .lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        if count > 0 {
                            Text("\(count.formatted()) \(count == 1 ? "Ripple" : "Ripples")")
                        }
                        if let lastActivityAt = preview?.lastActivityAt {
                            Text("Active \(relativeWaveActivity(lastActivityAt))")
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                }

                Spacer(minLength: 4)
                if let unread = preview?.unreadCount, unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(C.watch)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(unread) unread replies")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(C.textTertiary)
                        .padding(.top, 10)
                }
            }
            .padding(14)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) Ripples\(preview.map { ", \($0.unreadCount) unread" } ?? "")")
    }

    private func mobileWaveConversationHeader(for detail: VibeDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: selectedWave.map(waveSystemImage) ?? "house.fill")
                    .foregroundStyle(C.watch)
                Text(selectedWave?.name ?? "Vibe Home")
                    .font(.headline)
                    .foregroundStyle(C.text)
                Spacer()
                if let wave = selectedWave {
                    Text(waveTypeLabel(wave.type))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(C.watch)
                }
            }
            Text(selectedWave?.description
                 ?? "Everything happening across \(detail.club.name).")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .lineLimit(3)
            if let preview = selectedWaveSlug.flatMap({ waveDirectoryPreviews[$0] }),
               preview.unreadCount > 0 {
                Label("\(preview.unreadCount) unread replies", systemImage: "circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.watch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.elevated)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var homeDirectoryPreview: WaveDirectoryPreview? {
        let first = waveFeeds[feedKey(nil)]?.ripples.first
        return preview(from: first)
    }

    private func preview(from ripple: Ripple?) -> WaveDirectoryPreview? {
        guard let ripple else { return nil }
        return WaveDirectoryPreview(
            text: ripple.conversationSummary?.latestReplies.last?.content
                ?? ripple.body,
            lastActivityAt: ripple.conversationSummary?.lastActivityAt
                ?? ripple.publishedAt
                ?? ripple.createdAt,
            unreadCount: ripple.conversationSummary?.unreadCount ?? 0
        )
    }

    @MainActor
    private func loadWaveDirectoryPreviews(for availableWaves: [VibeWave]) async {
        for wave in availableWaves {
            if wave.directoryPreview != nil || wave.lastActivityAt != nil
                || wave.unreadCount > 0 || wave.activeConversationCount > 0 {
                continue
            }
            guard waveDirectoryPreviews[wave.slug] == nil else { continue }
            do {
                let page = try await api.vibeRipples(slug: slug, wave: wave.slug)
                guard waves.contains(where: { $0.slug == wave.slug }) else { return }
                waveDirectoryPreviews[wave.slug] = preview(from: page.posts.first)
                if waveFeeds[feedKey(wave.slug)] == nil {
                    waveFeeds[feedKey(wave.slug)] = CachedWaveFeed(
                        ripples: page.posts,
                        nextCursor: page.nextCursor,
                        resourceCategories: page.resourceCategories
                    )
                }
            } catch {
                // Directory metadata is additive; a failed preview must not hide an authorized Wave.
            }
        }
    }

    @MainActor
    private func openDedicatedWave(_ waveSlug: String) async {
        showsCommunityHomeConversation = false
        await switchWave(to: waveSlug)
    }

    @MainActor
    private func returnToWaveDirectory() {
        cacheCurrentFeed()
        selectedWaveSlug = nil
        showsCommunityHomeConversation = false
        selectedResourceCategory = nil
        bookmarkedResourcesOnly = false
        if let cached = waveFeeds[feedKey(nil)] {
            ripples = cached.ripples
            nextCursor = cached.nextCursor
            resourceCategories = cached.resourceCategories
        }
    }

    private func relativeWaveActivity(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return "recently"
        }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func isWaveMessageGrouped(_ ripple: Ripple?, after previous: Ripple?) -> Bool {
        guard let ripple, let previous,
              ripple.author.id == previous.author.id,
              ripple.wave?.id == previous.wave?.id,
              ripple.pinnedAt == nil,
              previous.pinnedAt == nil,
              let waveType = ripple.wave?.type,
              waveType == .general || waveType == .custom else {
            return false
        }
        let currentValue = ripple.publishedAt ?? ripple.createdAt
        let previousValue = previous.publishedAt ?? previous.createdAt
        guard let currentDate = waveMessageDate(currentValue),
              let previousDate = waveMessageDate(previousValue) else {
            return false
        }
        let interval = currentDate.timeIntervalSince(previousDate)
        return interval >= 0 && interval <= 10 * 60
    }

    private func waveMessageDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private var waveConversationHeader: some View {
        Button {
            C.lightHaptic()
            showsWaveDirectory = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedWave.map(waveSystemImage) ?? "house")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.watch)
                    .frame(width: 34, height: 34)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedWave?.name ?? "Vibe Home")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Text("Open Waves")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(12)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Waves. Current Wave: \(selectedWave?.name ?? "Vibe Home")")
    }

    private var waveContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOW VIEWING")
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(C.watch)
            Text(selectedWave?.name ?? "\(detail?.club.name ?? "Vibe") Home")
                .font(.headline)
                .foregroundStyle(C.text)
            Text(selectedWave?.description
                 ?? "Everything happening across \(detail?.club.name ?? "this Vibe").")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .lineLimit(3)
            if let wave = selectedWave {
                HStack(spacing: 12) {
                    Label(waveTypeLabel(wave.type), systemImage: waveSystemImage(wave))
                    Text(wave.visibility.capitalized)
                    if wave.requiresPostApproval { Text("Approval required") }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(C.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.elevated)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var resourceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                resourceFilterChip("All", selected: selectedResourceCategory == nil && !bookmarkedResourcesOnly) {
                    await applyResourceFilter(category: nil, bookmarkedOnly: false)
                }
                if auth.isAuthenticated {
                    resourceFilterChip("Saved", systemImage: "bookmark.fill", selected: bookmarkedResourcesOnly) {
                        await applyResourceFilter(category: nil, bookmarkedOnly: !bookmarkedResourcesOnly)
                    }
                }
                ForEach(resourceCategories, id: \.self) { category in
                    resourceFilterChip(category, selected: selectedResourceCategory == category && !bookmarkedResourcesOnly) {
                        await applyResourceFilter(category: category, bookmarkedOnly: false)
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resource filters")
    }

    private func resourceFilterChip(
        _ title: String,
        systemImage: String? = nil,
        selected: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? C.bg : C.textMuted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? C.watch : C.elevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSwitchingWave)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @MainActor
    private func applyResourceFilter(category: String?, bookmarkedOnly: Bool) async {
        guard selectedWave?.type == .resources else { return }
        selectedResourceCategory = category
        bookmarkedResourcesOnly = bookmarkedOnly
        isSwitchingWave = true
        do {
            let page = try await api.vibeRipples(
                slug: slug,
                wave: selectedWaveSlug,
                resourceCategory: category,
                bookmarkedOnly: bookmarkedOnly
            )
            ripples = page.posts
            nextCursor = page.nextCursor
            if !page.resourceCategories.isEmpty {
                resourceCategories = page.resourceCategories
            }
            cacheCurrentFeed()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isSwitchingWave = false
    }

    private func waveDirectoryRow(
        title: String,
        detail: String,
        slug: String?,
        systemImage: String,
        count: Int = 0
    ) -> some View {
        let selected = selectedWaveSlug == slug
        return Button {
            showsWaveDirectory = false
            Task { await switchWave(to: slug) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? C.watch : C.textMuted)
                    .frame(width: 28)
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
                if count > 0 {
                    Text(count.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(C.textMuted)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(C.watch)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func waveDirectoryDetail(_ wave: VibeWave) -> String {
        if let description = wave.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        return "\(waveTypeLabel(wave.type)) conversation"
    }

    private func waveTypeLabel(_ type: VibeWaveType) -> String {
        switch type {
        case .announcements: "Announcements"
        case .questions: "Questions"
        case .events: "Events"
        case .resources: "Resources"
        case .media: "Media"
        case .staff: "Staff"
        case .general: "General"
        case .custom: "Custom"
        case .unknown(let value): value.isEmpty ? "Wave" : value.capitalized
        }
    }

    @MainActor
    private func switchWave(to waveSlug: String?) async {
        guard selectedWaveSlug != waveSlug || waveFeeds[feedKey(waveSlug)] == nil else { return }
        cacheCurrentFeed()
        selectedResourceCategory = nil
        bookmarkedResourcesOnly = false
        resourceCategories = []
        selectedWaveSlug = waveSlug
        await loadWaveSummaries(waveSlug)
        feedRequestID = UUID()
        let requestID = feedRequestID
        if let cached = waveFeeds[feedKey(waveSlug)] {
            ripples = cached.ripples
            nextCursor = cached.nextCursor
            resourceCategories = cached.resourceCategories
            isSwitchingWave = false
            return
        }
        ripples = []
        nextCursor = nil
        isSwitchingWave = true
        do {
            let page = try await api.vibeRipples(slug: slug, wave: waveSlug)
            guard requestID == feedRequestID, selectedWaveSlug == waveSlug else { return }
            ripples = page.posts
            nextCursor = page.nextCursor
            resourceCategories = page.resourceCategories
            waveFeeds[feedKey(waveSlug)] = CachedWaveFeed(
                ripples: page.posts,
                nextCursor: page.nextCursor,
                resourceCategories: page.resourceCategories
            )
        } catch {
            guard requestID == feedRequestID else { return }
            errorMessage = socialErrorMessage(error)
        }
        if requestID == feedRequestID { isSwitchingWave = false }
    }

    private func cacheCurrentFeed() {
        waveFeeds[feedKey(
            selectedWaveSlug,
            category: selectedResourceCategory,
            bookmarkedOnly: bookmarkedResourcesOnly
        )] = CachedWaveFeed(
            ripples: ripples,
            nextCursor: nextCursor,
            resourceCategories: resourceCategories
        )
    }

    private func feedKey(
        _ waveSlug: String?,
        category: String? = nil,
        bookmarkedOnly: Bool = false
    ) -> String {
        "\(waveSlug ?? "__home__")|\(category ?? "*")|\(bookmarkedOnly ? "saved" : "all")"
    }

    private var selectedWave: VibeWave? {
        waves.first { $0.slug == selectedWaveSlug }
    }

    private var showsEventsSection: Bool {
        selectedWaveSlug == nil || selectedWave?.type == .events
    }

    private func canPost(in detail: VibeDetailResponse) -> Bool {
        selectedWave?.capabilities.canPost ?? detail.capabilities.canPost
    }

    private func composerDestination(for detail: VibeDetailResponse) -> RippleComposerDestination {
        if let selectedWave {
            return .wave(
                vibeSlug: detail.club.slug,
                vibeName: detail.club.name,
                wave: selectedWave
            )
        }
        return .vibe(slug: detail.club.slug, name: detail.club.name)
    }

    private func composerPrompt(for detail: VibeDetailResponse) -> String {
        if let selectedWave {
            return "Create a Ripple in \(selectedWave.name)…"
        }
        return "Create a Ripple in \(detail.club.name)…"
    }

    private func waveSystemImage(_ wave: VibeWave) -> String {
        switch wave.type {
        case .announcements: "megaphone"
        case .questions: "questionmark.bubble"
        case .events: "calendar"
        case .resources: "bookmark"
        case .media: "play.rectangle"
        case .staff: "person.2.badge.gearshape"
        case .general, .custom, .unknown: "wave.3.right"
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
        if capabilities.canManageClub { count += 2 }
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

private struct VibeRulesView: View {
    let vibeSlug: String
    @Environment(\.dismiss) private var dismiss
    @State private var response: VibeRulesResponse?
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Group {
                if let response {
                    if response.rolloutPending {
                        ContentUnavailableView(
                            "Rules are being prepared",
                            systemImage: "clock.badge",
                            description: Text("This Vibe’s structured Rules are not available on this server yet.")
                        )
                    } else if response.rules.isEmpty {
                        ContentUnavailableView(
                            "No Rules published",
                            systemImage: "list.bullet.clipboard",
                            description: Text("This Vibe has not published structured community Rules.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(response.rules.enumerated()), id: \.element.id) { index, rule in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(index + 1)")
                                            .font(.caption.bold())
                                            .foregroundStyle(C.bg)
                                            .frame(width: 28, height: 28)
                                            .background(C.watch, in: Circle())
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(rule.title)
                                                .font(.headline)
                                                .foregroundStyle(C.text)
                                            Text(rule.description)
                                                .font(.subheadline)
                                                .foregroundStyle(C.textMuted)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(16)
                                    .background(C.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                }
                            }
                            .padding(C.pagePad)
                        }
                    }
                } else if let errorMessage {
                    SocialUnavailable(
                        title: "Rules couldn’t load",
                        message: errorMessage,
                        retry: { Task { await load() } }
                    )
                } else {
                    ProgressView("Loading Rules…").tint(C.watch)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Vibe Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: vibeSlug) { await load() }
    }

    @MainActor
    private func load() async {
        response = nil
        errorMessage = nil
        do {
            response = try await api.vibeRules(slug: vibeSlug)
        } catch {
            errorMessage = socialErrorMessage(error)
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
                option("Waves", detail: "Spaces, permissions, posting tools, and alerts", icon: "water.waves", destination: .waves)
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
