import SwiftUI

enum PulsePostingIdentityKind: String, Codable, Sendable {
    case user = "USER"
    case channel = "CHANNEL"
}

struct PulsePostingIdentity: Identifiable, Equatable, Sendable {
    let kind: PulsePostingIdentityKind
    let id: String
    let name: String
    let handle: String
    let imageURL: URL?
    let followerCount: Int?
    let verified: Bool
}

/// Design System 25-C. This changes only the actor for one new Ripple; it
/// never changes the viewer's feed, Vibes, Waves, account or workspace.
struct PulsePostingIdentitySheet: View {
    let identities: [PulsePostingIdentity]
    let selected: PulsePostingIdentity
    let busy: Bool
    let select: @MainActor (PulsePostingIdentity) -> Void
    let createChannel: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    Text("Everything you do stays under the name you pick here.")
                        .font(WestreemTokens.Typography.caption)
                        .foregroundStyle(WestreemTokens.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, WestreemTokens.Spacing.m)

                    Divider().overlay(WestreemTokens.Palette.lineSoft)

                    ForEach(identities) { identity in
                        identityRow(identity)
                    }

                    Button {
                        createChannel()
                    } label: {
                        HStack(spacing: WestreemTokens.Spacing.m) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(WestreemTokens.Palette.muted)
                                .frame(width: 44, height: 44)
                                .background(raisedSurface, in: Circle())
                                .overlay(Circle().stroke(WestreemTokens.Palette.lineHard))
                            Text("Create a channel")
                                .font(WestreemTokens.Typography.bodyEmphasized)
                                .foregroundStyle(WestreemTokens.Palette.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    Divider().overlay(WestreemTokens.Palette.lineSoft)

                    Text("SWITCHING CHANGES WHO POSTS, NOT WHAT YOU SEE\nYOUR FEED, VIBES AND WAVES STAY YOURS")
                        .font(WestreemTokens.Typography.monoSmall)
                        .foregroundStyle(WestreemTokens.Palette.textFaint)
                        .multilineTextAlignment(.center)
                        .tracking(0.8)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                }
            }
            .background(WestreemTokens.Palette.ink900)
            .navigationTitle("Post as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(WestreemTokens.Palette.muted)
                }
            }
        }
        .accessibilityIdentifier("pulse-posting-identity-25-c")
        .westreemAdaptiveSheet(detents: [.medium, .large])
    }

    private func identityRow(_ identity: PulsePostingIdentity) -> some View {
        let isSelected = identity.kind == selected.kind && identity.id == selected.id
        return Button {
            select(identity)
        } label: {
            HStack(spacing: WestreemTokens.Spacing.m) {
                identityAvatar(identity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.name)
                        .font(WestreemTokens.Typography.bodyEmphasized)
                        .foregroundStyle(WestreemTokens.Palette.text)
                        .lineLimit(1)
                    Text(identityMetadata(identity))
                        .font(WestreemTokens.Typography.monoSmall)
                        .foregroundStyle(WestreemTokens.Palette.textFaint)
                        .tracking(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(isSelected ? WestreemTokens.Palette.greenOn : .clear)
                    .frame(width: 24, height: 24)
                    .background(isSelected ? WestreemTokens.Palette.green : .clear, in: Circle())
                    .overlay(Circle().stroke(isSelected ? WestreemTokens.Palette.green : WestreemTokens.Palette.lineHard))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("\(identity.name), \(identityMetadata(identity))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(WestreemTokens.Palette.lineSoft).frame(height: 1)
        }
    }

    @ViewBuilder private func identityAvatar(_ identity: PulsePostingIdentity) -> some View {
        AsyncImage(url: identity.imageURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Text(initials(identity.name))
                    .font(WestreemTokens.Typography.monoSmall)
                    .foregroundStyle(WestreemTokens.Palette.greenSoft)
            }
        }
        .frame(width: 44, height: 44)
        .background(raisedSurface, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().stroke(WestreemTokens.Palette.lineHard))
        .accessibilityHidden(true)
    }

    private var raisedSurface: some ShapeStyle {
        LinearGradient(
            colors: [WestreemTokens.Palette.ink700, WestreemTokens.Palette.surfaceRaisedEnd],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func identityMetadata(_ identity: PulsePostingIdentity) -> String {
        if identity.kind == .user { return "@\(identity.handle) · YOU" }
        var value = "CHANNEL"
        if let count = identity.followerCount {
            value += " · \(count.formatted()) FOLLOWERS"
        }
        if identity.verified { value += " · VERIFIED" }
        return value
    }

    private func initials(_ value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).prefix(2)
        let result = words.compactMap(\.first).map(String.init).joined().uppercased()
        return result.isEmpty ? "WS" : result
    }
}
