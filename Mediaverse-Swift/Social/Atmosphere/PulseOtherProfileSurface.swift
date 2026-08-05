import SwiftUI

enum PulseOtherProfileTab: String, CaseIterable, Identifiable, Sendable {
    case ripples = "Ripples"
    case videos = "Videos"
    case shorts = "Shorts"
    case vibes = "Vibes"

    var id: String { rawValue }
}

struct PulseOtherProfileProjection: Equatable, Sendable {
    enum Relationship: String, Sendable { case none = "NONE", requested = "REQUESTED", following = "FOLLOWING", blocked = "BLOCKED" }
    enum Presence: String, Sendable { case online = "ONLINE", idle = "IDLE", offline = "OFFLINE" }

    struct User: Equatable, Sendable {
        let id: String
        let name: String
        let handle: String
        let imageURL: URL?
        let bannerURL: URL?
        let bio: String?
        let verified: Bool
    }

    struct Metrics: Equatable, Sendable {
        let followers: Int
        let following: Int
        let energy: Int
        let carries: Int
    }

    struct LiveExperience: Equatable, Sendable {
        let label: String
        let title: String
        let canJoin: Bool
    }

    struct SharedVibe: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let initials: String
        let avatarURL: URL?
    }

    let user: User
    let relationship: Relationship
    let canMessage: Bool
    let presence: Presence
    let presenceLabel: String
    let metrics: Metrics
    let live: LiveExperience?
    let sharedVibes: [SharedVibe]
    let canViewContent: Bool
}

/// Design System 25-B mobile other-person Pulse. All privacy, relationship,
/// presence, aggregate and shared-Vibe fields are server projections.
struct PulseOtherProfileSurface<Content: View>: View {
    let value: PulseOtherProfileProjection
    @Binding var activeTab: PulseOtherProfileTab
    let busy: Bool
    let back: @MainActor () -> Void
    let follow: @MainActor () -> Void
    let message: @MainActor () -> Void
    let more: @MainActor () -> Void
    let joinLive: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                liveAndSharedVibes
                tabStrip
                if value.canViewContent {
                    content()
                        .padding(.top, WestreemTokens.Spacing.l)
                } else {
                    privateState
                }
            }
        }
        .background(WestreemTokens.Palette.ink950.ignoresSafeArea())
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("pulse-other-profile-25-b")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                banner
                    .frame(height: 100)
                    .clipped()
                HStack {
                    circleControl("chevron.left", label: "Back", action: back)
                    Spacer()
                    circleControl("ellipsis", label: "More profile actions", action: more)
                }
                .padding(.horizontal, WestreemTokens.Spacing.m)
                .padding(.top, WestreemTokens.Spacing.m)
            }

            HStack(alignment: .bottom, spacing: WestreemTokens.Spacing.m) {
                profileAvatar
                    .offset(y: -28)
                    .padding(.bottom, -28)
                Spacer(minLength: 0)
                Button(relationshipLabel) { follow() }
                    .font(WestreemTokens.Typography.bodyEmphasized)
                    .foregroundStyle(value.relationship == .none ? WestreemTokens.Palette.greenOn : WestreemTokens.Palette.text)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(value.relationship == .none ? AnyShapeStyle(WestreemTokens.Palette.green) : raisedSurface)
                    .overlay(Capsule().stroke(value.relationship == .none ? .clear : WestreemTokens.Palette.lineHard))
                    .clipShape(Capsule())
                    .disabled(busy || value.relationship == .blocked)
                if value.canMessage {
                    circleControl("message", label: "Message", action: message)
                }
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)

            HStack(spacing: WestreemTokens.Spacing.s) {
                Text(value.user.name)
                    .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 21, relativeTo: .title2))
                    .lineLimit(1)
                if value.user.verified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(WestreemTokens.Palette.green)
                        .accessibilityLabel("Verified")
                }
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .padding(.top, WestreemTokens.Spacing.m)

            Text("@\(value.user.handle) · \(value.presenceLabel)")
                .font(WestreemTokens.Typography.monoSmall)
                .foregroundStyle(WestreemTokens.Palette.textFaint)
                .tracking(0.7)
                .lineLimit(1)
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .padding(.top, WestreemTokens.Spacing.xs)

            if let bio = value.user.bio, !bio.isEmpty {
                Text(bio)
                    .font(WestreemTokens.Typography.body)
                    .foregroundStyle(WestreemTokens.Palette.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WestreemTokens.Spacing.l)
                    .padding(.top, WestreemTokens.Spacing.m)
            }

            HStack {
                metric(value.metrics.followers, label: "FOLLOWERS")
                metric(value.metrics.following, label: "FOLLOWING")
                metric(value.metrics.energy, label: "ENERGY")
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .padding(.vertical, 20)
        }
        .background(WestreemTokens.Palette.ink900)
    }

    @ViewBuilder private var liveAndSharedVibes: some View {
        VStack(spacing: 0) {
            if let live = value.live {
                HStack(spacing: WestreemTokens.Spacing.m) {
                    Circle().fill(WestreemTokens.Palette.green).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(live.label.uppercased())
                            .font(WestreemTokens.Typography.monoSmall)
                            .foregroundStyle(WestreemTokens.Palette.green)
                        Text(live.title)
                            .font(WestreemTokens.Typography.bodyEmphasized)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if live.canJoin {
                        Button("JOIN") { joinLive() }
                            .font(WestreemTokens.Typography.monoSmall)
                            .foregroundStyle(WestreemTokens.Palette.green)
                            .padding(.horizontal, WestreemTokens.Spacing.l)
                            .frame(minHeight: 44)
                            .overlay(Capsule().stroke(WestreemTokens.Palette.lineHard))
                    }
                }
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .padding(.vertical, WestreemTokens.Spacing.m)
                .overlay(alignment: .bottom) { Divider().overlay(WestreemTokens.Palette.lineSoft) }
            }

            VStack(alignment: .leading, spacing: WestreemTokens.Spacing.s) {
                Text("\(value.sharedVibes.count) VIBES IN COMMON")
                    .font(WestreemTokens.Typography.monoSmall)
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .tracking(0.8)
                HStack(spacing: -8) {
                    ForEach(value.sharedVibes.prefix(3)) { vibe in
                        sharedVibeAvatar(vibe)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .padding(.vertical, WestreemTokens.Spacing.m)
        }
        .background(WestreemTokens.Palette.ink900)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(PulseOtherProfileTab.allCases) { tab in
                    Button(tab.rawValue) {
                        withAnimation(WestreemTokens.Easing.fast) { activeTab = tab }
                        C.lightHaptic()
                    }
                    .font(WestreemTokens.Typography.bodyEmphasized)
                    .foregroundStyle(activeTab == tab ? WestreemTokens.Palette.text : WestreemTokens.Palette.muted)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 48)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(activeTab == tab ? WestreemTokens.Palette.green : .clear)
                            .frame(height: 2)
                    }
                    .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
                }
            }
        }
        .background(WestreemTokens.Palette.ink900)
        .overlay(alignment: .top) { Divider().overlay(WestreemTokens.Palette.lineSoft) }
        .overlay(alignment: .bottom) { Divider().overlay(WestreemTokens.Palette.lineSoft) }
        .accessibilityLabel("\(value.user.name) Pulse sections")
    }

    private var privateState: some View {
        VStack(spacing: WestreemTokens.Spacing.s) {
            Text("This account is private")
                .font(WestreemTokens.Typography.heading)
            Text("Follow this account to request access to its Pulse.")
                .font(WestreemTokens.Typography.caption)
                .foregroundStyle(WestreemTokens.Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, WestreemTokens.Spacing.xl)
        .padding(.vertical, 64)
    }

    @ViewBuilder private var banner: some View {
        AsyncImage(url: value.user.bannerURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(WestreemTokens.Palette.surfaceSelected)
                    .overlay(LinearGradient(colors: [.clear, WestreemTokens.Palette.ink900.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private var profileAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: value.user.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Text(initials(value.user.name))
                        .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 22, relativeTo: .title2))
                        .foregroundStyle(WestreemTokens.Palette.greenSoft)
                }
            }
            .frame(width: 80, height: 80)
            .background(raisedSurface, in: Circle())
            .clipShape(Circle())
            .overlay(Circle().stroke(WestreemTokens.Palette.ink900, lineWidth: 4))

            Circle()
                .fill(presenceColor)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(WestreemTokens.Palette.ink900, lineWidth: 3))
                .accessibilityLabel(value.presence.rawValue.lowercased())
        }
    }

    private func sharedVibeAvatar(_ vibe: PulseOtherProfileProjection.SharedVibe) -> some View {
        AsyncImage(url: vibe.avatarURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Text(vibe.initials)
                    .font(WestreemTokens.Typography.monoSmall)
                    .foregroundStyle(WestreemTokens.Palette.greenSoft)
            }
        }
        .frame(width: 36, height: 36)
        .background(raisedSurface, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().stroke(WestreemTokens.Palette.ink900, lineWidth: 2))
        .accessibilityLabel(vibe.name)
    }

    private func metric(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 16, relativeTo: .body))
            Text(label)
                .font(WestreemTokens.Typography.monoSmall)
                .foregroundStyle(WestreemTokens.Palette.textFaint)
                .tracking(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circleControl(_ systemName: String, label: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var presenceColor: Color {
        switch value.presence {
        case .online: WestreemTokens.Palette.green
        case .idle: WestreemTokens.Palette.lavender
        case .offline: WestreemTokens.Palette.textFaint
        }
    }

    private var relationshipLabel: String {
        switch value.relationship {
        case .none: "Follow"
        case .requested: "Requested"
        case .following: "Following"
        case .blocked: "Blocked"
        }
    }

    private var raisedSurface: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private func initials(_ value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).prefix(2)
        let result = words.compactMap(\.first).map(String.init).joined().uppercased()
        return result.isEmpty ? "WS" : result
    }
}
