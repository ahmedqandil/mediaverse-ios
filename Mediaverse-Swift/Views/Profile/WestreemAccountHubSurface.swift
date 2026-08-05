import SwiftUI

enum WestreemAccountHubAction: String, CaseIterable, Hashable, Sendable {
    case editProfile
    case switchContext
    case history
    case collections
    case channel
    case profilePrivacy
    case notifications
    case security
    case billing
    case pairedDevices
    case affiliationRequests
    case signOut
}

struct WestreemAccountHubProjection: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let displayName: String
        let handle: String
        let avatarURL: URL?
        let followerCount: Int?
    }

    enum Visibility: String, Equatable, Sendable {
        case publicAccount = "PUBLIC ACCOUNT"
        case privateAccount = "PRIVATE ACCOUNT"
    }

    enum NotificationSummary: String, Equatable, Sendable {
        case pushAndInApp = "PUSH · IN APP"
        case push = "PUSH"
        case inApp = "IN APP"
        case off = "OFF"
    }

    let identity: Identity
    let hasMultipleContexts: Bool
    let hasChannel: Bool
    let visibility: Visibility
    let notificationSummary: NotificationSummary?
    let activeSessionCount: Int?
    let subscriptionCount: Int?
    let rentalCount: Int?
    let pairedTVCount: Int?
    let affiliationRequestCount: Int?
}

/// Design System 26-A. This is a projection-only surface: navigation icons,
/// counts and mutations are injected, so the view cannot become local product
/// authority while the account/session contracts remain release-blocked.
struct WestreemAccountHubSurface: View {
    private struct Row: Identifiable {
        let action: WestreemAccountHubAction
        let label: String
        let metadata: String
        var id: WestreemAccountHubAction { action }
    }

    let value: WestreemAccountHubProjection
    let icon: @MainActor (WestreemAccountHubAction) -> AnyView
    let onAction: @MainActor (WestreemAccountHubAction) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Account")
                    .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 17, relativeTo: .headline))
                    .frame(minHeight: 48)

                identity
                    .padding(.top, WestreemTokens.Spacing.m)
                library
                    .padding(.top, 28)
                accountRows
                    .padding(.top, 28)
                signOut
                    .padding(.top, 28)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(WestreemTokens.Palette.ink950.ignoresSafeArea())
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("westreem-account-hub-26-a")
    }

    private var identity: some View {
        VStack(spacing: 0) {
            AsyncImage(url: value.identity.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Text(initials(value.identity.displayName))
                        .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 17, relativeTo: .body))
                        .foregroundStyle(WestreemTokens.Palette.greenSoft)
                }
            }
            .frame(width: 84, height: 84)
            .background(raisedSurface, in: Circle())
            .clipShape(Circle())
            .overlay(Circle().stroke(WestreemTokens.Palette.lineHard))

            Text(value.identity.displayName)
                .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 20, relativeTo: .title3))
                .padding(.top, WestreemTokens.Spacing.m)

            Text("@\(value.identity.handle) · \(compactCount(value.identity.followerCount)) FOLLOWERS")
                .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                .foregroundStyle(WestreemTokens.Palette.textFaint)
                .tracking(0.8)
                .padding(.top, WestreemTokens.Spacing.xs)

            HStack(spacing: WestreemTokens.Spacing.s) {
                Button("Edit profile") { onAction(.editProfile) }
                    .buttonStyle(AccountPrimaryButtonStyle())
                if value.hasMultipleContexts {
                    Button("Switch context") { onAction(.switchContext) }
                        .buttonStyle(AccountSecondaryButtonStyle())
                }
            }
            .padding(.top, WestreemTokens.Spacing.l)
        }
        .multilineTextAlignment(.center)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: WestreemTokens.Spacing.s) {
            sectionLabel("YOUR WESTREEM")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: WestreemTokens.Spacing.s), GridItem(.flexible())], spacing: WestreemTokens.Spacing.s) {
                libraryCard(.history, label: "History", metadata: "Resume watching")
                libraryCard(.collections, label: "Collections", metadata: "Saved clips")
                if value.hasChannel {
                    libraryCard(.channel, label: "Channel", metadata: "Manage your channel")
                }
            }
        }
    }

    private var accountRows: some View {
        VStack(alignment: .leading, spacing: WestreemTokens.Spacing.s) {
            sectionLabel("ACCOUNT")
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Button { onAction(row.action) } label: {
                        HStack(spacing: WestreemTokens.Spacing.m) {
                            icon(row.action)
                                .frame(width: 36, height: 36)
                                .foregroundStyle(WestreemTokens.Palette.green)
                                .background(WestreemTokens.Palette.surfaceSelected, in: Circle())
                            VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                                Text(row.label)
                                    .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 13, relativeTo: .body))
                                    .foregroundStyle(WestreemTokens.Palette.text)
                                Text(row.metadata)
                                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                                    .tracking(0.6)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: WestreemTokens.Spacing.s)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(WestreemTokens.Palette.textFaint)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, WestreemTokens.Spacing.l)
                        .frame(minHeight: 64)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if row.id != rows.last?.id {
                            Rectangle().fill(WestreemTokens.Palette.lineSoft).frame(height: 1)
                        }
                    }
                }
            }
            .background(WestreemTokens.Palette.ink800)
            .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card).stroke(WestreemTokens.Palette.lineEdge))
        }
    }

    private var signOut: some View {
        Button { onAction(.signOut) } label: {
            HStack(spacing: WestreemTokens.Spacing.m) {
                icon(.signOut)
                    .frame(width: 36, height: 36)
                    .background(WestreemTokens.Palette.surfaceSelected, in: Circle())
                Text("Sign out")
                    .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 13, relativeTo: .body))
                Spacer()
            }
            .foregroundStyle(WestreemTokens.Palette.pink)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .frame(minHeight: 56)
            .background(WestreemTokens.Palette.ink800)
            .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card).stroke(WestreemTokens.Palette.lineEdge))
        }
        .buttonStyle(.plain)
    }

    private var rows: [Row] {
        [
            Row(action: .profilePrivacy, label: "Profile & privacy", metadata: value.visibility.rawValue),
            Row(action: .notifications, label: "Notifications", metadata: value.notificationSummary?.rawValue ?? "UNAVAILABLE"),
            Row(action: .security, label: "Security", metadata: countLabel(value.activeSessionCount, singular: "active session", plural: "active sessions")),
            Row(action: .billing, label: "Billing & rentals", metadata: billingMetadata),
            Row(action: .pairedDevices, label: "Paired devices", metadata: countLabel(value.pairedTVCount, singular: "TV", plural: "TVs")),
            Row(action: .affiliationRequests, label: "Affiliation requests", metadata: value.affiliationRequestCount.map { "\($0) WAITING" } ?? "UNAVAILABLE"),
        ]
    }

    private var billingMetadata: String {
        guard let subscriptions = value.subscriptionCount, let rentals = value.rentalCount else { return "UNAVAILABLE" }
        return "\(countLabel(subscriptions, singular: "subscription", plural: "subscriptions")) · \(countLabel(rentals, singular: "rental", plural: "rentals"))"
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
            .foregroundStyle(WestreemTokens.Palette.textFaint)
            .tracking(0.9)
    }

    private func libraryCard(_ action: WestreemAccountHubAction, label: String, metadata: String) -> some View {
        Button { onAction(action) } label: {
            VStack(alignment: .leading, spacing: 0) {
                icon(action)
                    .foregroundStyle(WestreemTokens.Palette.green)
                Spacer(minLength: WestreemTokens.Spacing.s)
                Text(label)
                    .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 13, relativeTo: .body))
                    .foregroundStyle(WestreemTokens.Palette.text)
                Text(metadata)
                    .font(.custom(WestreemTokens.FontFamily.bodyRegular, size: 11, relativeTo: .caption))
                    .foregroundStyle(WestreemTokens.Palette.muted)
                    .padding(.top, WestreemTokens.Spacing.xs)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(WestreemTokens.Spacing.m)
            .background(WestreemTokens.Palette.ink800)
            .clipShape(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: WestreemTokens.Radius.card).stroke(WestreemTokens.Palette.lineEdge))
        }
        .buttonStyle(.plain)
    }

    private var raisedSurface: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "UNAVAILABLE" }
        if value < 1_000 { return String(value) }
        let compact = Double(value) / 1_000
        return compact.rounded() == compact ? "\(Int(compact))K" : String(format: "%.1fK", compact)
    }

    private func countLabel(_ value: Int?, singular: String, plural: String) -> String {
        guard let value else { return "UNAVAILABLE" }
        return "\(value) \(value == 1 ? singular : plural)".uppercased()
    }

    private func initials(_ name: String) -> String {
        let result = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "WS" : result.uppercased()
    }
}

private struct AccountPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 13, relativeTo: .body))
            .foregroundStyle(WestreemTokens.Palette.greenOn)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .background(WestreemTokens.Palette.green, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(WestreemTokens.Easing.fast, value: configuration.isPressed)
    }
}

private struct AccountSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 13, relativeTo: .body))
            .foregroundStyle(WestreemTokens.Palette.text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .background(LinearGradient(
                colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
                startPoint: .top,
                endPoint: .bottom
            ), in: Capsule())
            .overlay(Capsule().stroke(WestreemTokens.Palette.lineHard))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(WestreemTokens.Easing.fast, value: configuration.isPressed)
    }
}
