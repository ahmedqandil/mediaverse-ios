import SwiftUI

enum WestreemSecuritySessionKind: String, Hashable, Sendable {
    case phone
    case computer
    case tv

    var systemImage: String {
        switch self {
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .tv: "appletv"
        }
    }
}

struct WestreemSecuritySession: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let metadata: String
    let kind: WestreemSecuritySessionKind
    let current: Bool
}

struct WestreemSecurityProjection: Equatable, Sendable {
    let email: String
    let connectedAccounts: [String]
    let sessions: [WestreemSecuritySession]
}

/// Design System 26-D. Session and deletion authority are injected; this view
/// never treats device-local state as the cross-client session registry.
struct WestreemSecuritySurface: View {
    let value: WestreemSecurityProjection
    let busySessionID: String?
    let busyAllOthers: Bool
    let onBack: @MainActor () -> Void
    let onEmail: @MainActor () -> Void
    let onConnectedAccounts: @MainActor () -> Void
    let onSignOutSession: @MainActor (String) -> Void
    let onSignOutOthers: @MainActor () -> Void
    let onDeleteAccount: @MainActor () -> Void

    private var otherSessions: [WestreemSecuritySession] {
        value.sessions.filter { !$0.current }
    }

    private var connectedAccounts: String {
        value.connectedAccounts.isEmpty
            ? "NONE CONNECTED"
            : value.connectedAccounts.joined(separator: " · ").uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                sectionLabel("SIGN IN")
                detailRow(label: "EMAIL", value: value.email, action: onEmail)
                detailRow(label: "Connected accounts", value: connectedAccounts, emphasized: true, action: onConnectedAccounts)

                HStack(alignment: .top, spacing: WestreemTokens.Spacing.m) {
                    Image(systemName: "shield")
                        .foregroundStyle(WestreemTokens.Palette.lavender)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                        Text("There is no password")
                            .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 14, relativeTo: .body))
                        Text("You sign in with Apple, Google or a code by email — nothing to reset or leak.")
                            .font(.custom(WestreemTokens.FontFamily.bodyRegular, size: 12, relativeTo: .caption))
                            .foregroundStyle(WestreemTokens.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WestreemTokens.Spacing.l)
                .padding(.vertical, WestreemTokens.Spacing.m)
                .overlay(alignment: .bottom) { divider }

                sessionSectionHeader
                ForEach(value.sessions) { session in
                    sessionRow(session)
                }

                sectionLabel("THIS ACCOUNT")
                Button { onDeleteAccount() } label: {
                    Text("Delete account")
                        .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 14, relativeTo: .body))
                        .foregroundStyle(WestreemTokens.Palette.pink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(WestreemTokens.Palette.pink.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(WestreemTokens.Palette.pink.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WestreemTokens.Spacing.l)

                Text("DELETING ASKS TWICE AND NAMES WHAT GOES\nRIPPLES, WAVES, COLLECTIONS AND CHANNELS YOU OWN")
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WestreemTokens.Spacing.l)
                    .padding(.top, WestreemTokens.Spacing.s)
                    .padding(.bottom, WestreemTokens.Spacing.xl)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(WestreemTokens.Palette.ink950.ignoresSafeArea())
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("westreem-security-26-d")
    }

    private var header: some View {
        HStack(spacing: WestreemTokens.Spacing.m) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .background(raisedSurface, in: Circle())
                    .overlay(Circle().stroke(WestreemTokens.Palette.lineHard))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Text("Security")
                .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 17, relativeTo: .headline))
            Spacer()
        }
        .padding(.horizontal, WestreemTokens.Spacing.l)
        .frame(minHeight: 56)
    }

    private var sessionSectionHeader: some View {
        HStack(spacing: WestreemTokens.Spacing.s) {
            Text("WHERE YOU ARE SIGNED IN")
                .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                .foregroundStyle(WestreemTokens.Palette.textFaint)
                .tracking(0.9)
            Spacer(minLength: 0)
            if !otherSessions.isEmpty {
                Button {
                    onSignOutOthers()
                } label: {
                    Text(busyAllOthers ? "SIGNING OUT…" : "SIGN OUT \(otherSessions.count) OTHERS")
                        .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                        .foregroundStyle(WestreemTokens.Palette.pink)
                }
                .buttonStyle(.plain)
                .disabled(busyAllOthers)
            }
        }
        .padding(.horizontal, WestreemTokens.Spacing.l)
        .padding(.top, WestreemTokens.Spacing.l)
        .padding(.bottom, WestreemTokens.Spacing.s)
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
            .foregroundStyle(WestreemTokens.Palette.textFaint)
            .tracking(0.9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .padding(.top, WestreemTokens.Spacing.l)
            .padding(.bottom, WestreemTokens.Spacing.s)
    }

    private func sessionRow(_ session: WestreemSecuritySession) -> some View {
        HStack(spacing: WestreemTokens.Spacing.m) {
            Image(systemName: session.kind.systemImage)
                .frame(width: 36, height: 36)
                .foregroundStyle(session.current ? WestreemTokens.Palette.green : WestreemTokens.Palette.textFaint)
                .background(session.current ? WestreemTokens.Palette.green.opacity(0.1) : WestreemTokens.Palette.ink700, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(session.current ? .clear : WestreemTokens.Palette.lineHard))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                HStack(spacing: WestreemTokens.Spacing.s) {
                    Text(session.name)
                        .font(.custom(session.current ? WestreemTokens.FontFamily.bodyBold : WestreemTokens.FontFamily.bodySemibold, size: 14, relativeTo: .body))
                        .lineLimit(1)
                    if session.current {
                        Text("THIS DEVICE")
                            .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 8, relativeTo: .caption2))
                            .foregroundStyle(WestreemTokens.Palette.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(WestreemTokens.Palette.green.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(WestreemTokens.Palette.green.opacity(0.35)))
                    }
                }
                Text(session.metadata.uppercased())
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: WestreemTokens.Spacing.s)
            Button {
                onSignOutSession(session.id)
            } label: {
                Text(busySessionID == session.id ? "WORKING…" : session.current ? "SIGN OUT" : "REMOVE")
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                    .foregroundStyle(WestreemTokens.Palette.pink)
            }
            .buttonStyle(.plain)
            .disabled(busySessionID == session.id)
        }
        .padding(.horizontal, WestreemTokens.Spacing.l)
        .frame(minHeight: 62)
        .overlay(alignment: .leading) {
            if session.current {
                Rectangle().fill(WestreemTokens.Palette.green).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) { divider }
    }

    private func detailRow(label: String, value: String, emphasized: Bool = false, action: @escaping @MainActor () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: WestreemTokens.Spacing.m) {
                VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                    Text(label)
                        .font(.custom(emphasized ? WestreemTokens.FontFamily.bodySemibold : WestreemTokens.FontFamily.monoMedium, size: emphasized ? 14 : 9, relativeTo: .body))
                        .foregroundStyle(emphasized ? WestreemTokens.Palette.text : WestreemTokens.Palette.textFaint)
                    Text(value)
                        .font(.custom(emphasized ? WestreemTokens.FontFamily.monoMedium : WestreemTokens.FontFamily.bodyRegular, size: emphasized ? 9 : 14, relativeTo: .body))
                        .foregroundStyle(emphasized ? WestreemTokens.Palette.textFaint : WestreemTokens.Palette.text)
                        .lineLimit(1)
                }
                Spacer(minLength: WestreemTokens.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { divider }
    }

    private var divider: some View {
        Rectangle().fill(WestreemTokens.Palette.lineSoft).frame(height: 1)
    }

    private var raisedSurface: AnyShapeStyle {
        AnyShapeStyle(LinearGradient(
            colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
            startPoint: .top,
            endPoint: .bottom
        ))
    }
}
