import SwiftUI

enum WestreemProfileField: String, Hashable, Sendable {
    case displayName
    case handle
    case bio
}

enum WestreemPrivacyPreference: String, Hashable, Sendable {
    case privateAccount
    case showOnline
    case showWatchActivity
}

struct WestreemProfilePrivacyProjection: Equatable, Sendable {
    let profileImageURL: URL?
    let bannerURL: URL?
    let displayName: String
    let handle: String
    let bio: String
    let privateAccount: Bool
    let showOnline: Bool
    let showWatchActivity: Bool
}

/// Design System 26-B. Every edit, media selection and privacy transition is
/// injected so this keyed view cannot substitute client-local authority.
struct WestreemProfilePrivacySurface: View {
    let value: WestreemProfilePrivacyProjection
    let busyPreference: WestreemPrivacyPreference?
    let onBack: @MainActor () -> Void
    let onProfileImage: @MainActor () -> Void
    let onBanner: @MainActor () -> Void
    let onEditField: @MainActor (WestreemProfileField) -> Void
    let onToggle: @MainActor (WestreemPrivacyPreference, Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                sectionLabel("YOU")
                mediaRow(
                    title: "Profile image",
                    metadata: "TAP TO CHANGE · POSITION AFTER PICKING",
                    preview: AnyView(profileImage),
                    action: onProfileImage
                )
                mediaRow(
                    title: "Banner",
                    metadata: "3:1 · POSITION AFTER PICKING",
                    preview: AnyView(banner),
                    action: onBanner
                )
                fieldRow(.displayName, label: "DISPLAY NAME", current: value.displayName)
                fieldRow(.handle, label: "HANDLE", current: "@\(value.handle)")
                fieldRow(.bio, label: "BIO", current: value.bio)

                sectionLabel("WHO CAN SEE YOU")
                preferenceRow(
                    .privateAccount,
                    label: "Private account",
                    description: "People send a follow request. Accepting also adds them to Contacts.",
                    checked: value.privateAccount
                )
                preferenceRow(
                    .showOnline,
                    label: "Show when you are online",
                    description: "Your presence dot and “in a vibe” state.",
                    checked: value.showOnline
                )
                preferenceRow(
                    .showWatchActivity,
                    label: "Show your watch activity",
                    description: "Continue watching and what you have finished.",
                    checked: value.showWatchActivity
                )

                Text("PUBLIC ACCOUNTS APPROVE FOLLOWS AND ADD CONTACTS IMMEDIATELY\nTURNING PRIVATE ON DOES NOT REMOVE EXISTING FOLLOWERS")
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                    .foregroundStyle(WestreemTokens.Palette.textFaint)
                    .tracking(0.6)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WestreemTokens.Spacing.l)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(WestreemTokens.Palette.ink950.ignoresSafeArea())
        .foregroundStyle(WestreemTokens.Palette.text)
        .accessibilityIdentifier("westreem-profile-privacy-26-b")
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
            Text("Profile & privacy")
                .font(.custom(WestreemTokens.FontFamily.bodyBold, size: 17, relativeTo: .headline))
            Spacer()
        }
        .padding(.horizontal, WestreemTokens.Spacing.l)
        .frame(minHeight: 56)
    }

    private var profileImage: some View {
        AsyncImage(url: value.profileImageURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Text(initials(value.displayName))
                    .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 15, relativeTo: .body))
                    .foregroundStyle(WestreemTokens.Palette.greenSoft)
            }
        }
        .frame(width: 48, height: 48)
        .background(raisedSurface, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().stroke(WestreemTokens.Palette.lineHard))
    }

    private var banner: some View {
        AsyncImage(url: value.bannerURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(WestreemTokens.Palette.surfaceSelected)
            }
        }
        .frame(width: 72, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(WestreemTokens.Palette.lineHard))
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

    private func mediaRow(title: String, metadata: String, preview: AnyView, action: @escaping @MainActor () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: WestreemTokens.Spacing.m) {
                preview
                VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                    Text(title)
                        .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 14, relativeTo: .body))
                        .foregroundStyle(WestreemTokens.Palette.text)
                    Text(metadata)
                        .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                        .foregroundStyle(WestreemTokens.Palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: WestreemTokens.Spacing.s)
                chevron
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { divider }
    }

    private func fieldRow(_ field: WestreemProfileField, label: String, current: String) -> some View {
        Button { onEditField(field) } label: {
            HStack(spacing: WestreemTokens.Spacing.m) {
                VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                    Text(label)
                        .font(.custom(WestreemTokens.FontFamily.monoMedium, size: 9, relativeTo: .caption2))
                        .foregroundStyle(WestreemTokens.Palette.textFaint)
                        .tracking(0.8)
                    Text(current)
                        .font(.custom(WestreemTokens.FontFamily.bodyRegular, size: 14, relativeTo: .body))
                        .foregroundStyle(WestreemTokens.Palette.text)
                        .lineLimit(1)
                }
                Spacer(minLength: WestreemTokens.Spacing.s)
                chevron
            }
            .padding(.horizontal, WestreemTokens.Spacing.l)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { divider }
    }

    private func preferenceRow(_ preference: WestreemPrivacyPreference, label: String, description: String, checked: Bool) -> some View {
        HStack(alignment: .top, spacing: WestreemTokens.Spacing.m) {
            VStack(alignment: .leading, spacing: WestreemTokens.Spacing.xs) {
                Text(label)
                    .font(.custom(WestreemTokens.FontFamily.bodySemibold, size: 14, relativeTo: .body))
                Text(description)
                    .font(.custom(WestreemTokens.FontFamily.bodyRegular, size: 12, relativeTo: .caption))
                    .foregroundStyle(WestreemTokens.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WestreemTokens.Spacing.s)
            Button {
                C.lightHaptic()
                onToggle(preference, !checked)
            } label: {
                ZStack(alignment: checked ? .trailing : .leading) {
                    Capsule()
                        .fill(checked ? WestreemTokens.Palette.green : WestreemTokens.Palette.ink700)
                        .overlay(Capsule().stroke(checked ? WestreemTokens.Palette.green : WestreemTokens.Palette.lineHard))
                    Circle()
                        .fill(checked ? WestreemTokens.Palette.greenOn : WestreemTokens.Palette.textFaint)
                        .frame(width: 19, height: 19)
                        .padding(3)
                }
                .frame(width: 42, height: 25)
            }
            .buttonStyle(.plain)
            .disabled(busyPreference == preference)
            .opacity(busyPreference == preference ? 0.45 : 1)
            .accessibilityLabel(label)
            .accessibilityValue(checked ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, WestreemTokens.Spacing.l)
        .padding(.vertical, WestreemTokens.Spacing.m)
        .frame(minHeight: 72)
        .overlay(alignment: .bottom) { divider }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(WestreemTokens.Palette.textFaint)
            .accessibilityHidden(true)
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

    private func initials(_ name: String) -> String {
        let result = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "WS" : result.uppercased()
    }
}
