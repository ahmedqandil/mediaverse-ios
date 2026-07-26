import SwiftUI

struct VibeDetailView: View {
    let slug: String
    @State private var detail: VibeDetailResponse?
    @State private var ripples: [Ripple] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var isMutatingRelationship = false
    @State private var relationshipNotice: String?
    @State private var errorMessage: String?
    @State private var showsAffiliations = false
    @State private var showsModeration = false
    @State private var showsInvitations = false
    @State private var showsSettings = false
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
                        RippleComposer(
                            destination: .vibe(slug: detail.club.slug, name: detail.club.name)
                        ) { ripple in
                            ripples.insert(ripple, at: 0)
                        }
                        .padding(.horizontal, C.pagePad)
                    }
                    ForEach(ripples) {
                        RippleCard(
                            ripple: $0,
                            allowsEngagement: features.rippleEngagementEnabled
                        )
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
            .padding(.bottom, C.bottomMenuClearance)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(detail?.club.name ?? "Vibe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if detail?.capabilities.canManageClub == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Manage Vibe settings")
                }
            }
            if detail?.capabilities.canInvite == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsInvitations = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Manage invitations")
                }
            }
            if detail?.capabilities.canModerateContent == true
                || detail?.capabilities.canModerateMembers == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsModeration = true
                    } label: {
                        Image(systemName: "checkmark.shield")
                    }
                    .accessibilityLabel("Moderate Vibe")
                }
            }
            if detail?.capabilities.canManageAffiliations == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAffiliations = true
                    } label: {
                        Image(systemName: "link")
                    }
                    .accessibilityLabel("Manage affiliations")
                }
            }
        }
        .sheet(isPresented: $showsAffiliations) {
            VibeAffiliationsView(slug: slug)
        }
        .sheet(isPresented: $showsModeration) {
            if let capabilities = detail?.capabilities {
                VibeModerationView(slug: slug, capabilities: capabilities)
            }
        }
        .sheet(isPresented: $showsInvitations) {
            if let detail {
                VibeInvitationsView(
                    slug: slug,
                    capabilities: detail.capabilities,
                    currentRole: detail.membership?.role
                )
            }
        }
        .sheet(isPresented: $showsSettings) {
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
        }
        .task(id: slug) { await load() }
        .refreshable { await load() }
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

    private var relationshipAction: (() -> Void)? {
        guard let detail else { return nil }
        let canMutate = detail.club.isPersonal
            ? detail.capabilities.canFollow || detail.following
            : detail.capabilities.canJoin
                || detail.capabilities.canRequestJoin
                || detail.capabilities.canLeave
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
            } else if detail.capabilities.canLeave {
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
}

struct RippleDetailView: View {
    let postId: String
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
                        allowsEngagement: features.rippleEngagementEnabled
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
            .padding(C.pagePad)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Ripple")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: postId) { await load() }
        .refreshable { await load() }
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
    let handle: String
    @State private var selectedTab: SocialProfileTab = .atmosphere
    @State private var ripples: [Ripple] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let features = SocialFeatureConfiguration.runtime()

    var body: some View {
        VStack(spacing: 0) {
            profileHeader
            MediaverseUnderlineTabStrip(
                items: [
                    MediaverseTabItem(id: SocialProfileTab.atmosphere.rawValue, label: "Atmo"),
                    MediaverseTabItem(id: SocialProfileTab.echoed.rawValue, label: "Echoed"),
                    MediaverseTabItem(id: SocialProfileTab.mentions.rawValue, label: "Mentions")
                ],
                selectedID: selectedTab.rawValue,
                fillsWidth: true,
                horizontalPadding: 0
            ) { value in
                guard let tab = SocialProfileTab(rawValue: value) else { return }
                selectedTab = tab
                Task { await load() }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isLoading, ripples.isEmpty {
                        ProgressView().tint(C.watch).padding(.top, 60)
                    } else {
                        ForEach(ripples) {
                            RippleCard(
                                ripple: $0,
                                allowsEngagement: features.rippleEngagementEnabled
                            )
                        }
                        if nextCursor != nil {
                            ProgressView().tint(C.watch).task { await loadMore() }
                        }
                    }
                }
                .padding(C.pagePad)
                .padding(.bottom, C.bottomMenuClearance)
            }
            .refreshable { await load() }
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: handle) { await load() }
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

    private var profileHeader: some View {
        HStack(spacing: 12) {
            SocialIdentityAvatar(image: nil, name: handle, size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("@\(handle)").font(.title3.bold()).foregroundStyle(C.text)
                Text("Atmosphere").font(.caption).foregroundStyle(C.textMuted)
            }
            Spacer()
        }
        .padding(C.pagePad)
        .background(C.surface)
    }

    private func load() async {
        isLoading = true
        do {
            let page = try await api.discover(
                mode: .latest,
                authorHandle: handle,
                profileTab: selectedTab
            )
            ripples = page.posts
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            ripples = []
            nextCursor = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await api.discover(
                mode: .latest,
                cursor: cursor,
                authorHandle: handle,
                profileTab: selectedTab
            )
            let existing = Set(ripples.map(\.id))
            ripples.append(contentsOf: page.posts.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = socialErrorMessage(error)
        }
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
        if detail.capabilities.canLeave {
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
