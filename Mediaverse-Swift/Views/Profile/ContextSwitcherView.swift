import SwiftUI

/// Context switcher sheet — lists admin/network/channel/user contexts.
/// Mirrors the UserContextMenu component in TopBar.tsx
struct ContextSwitcherView: View {

    @Binding var contexts: [ActiveContext]
    @Binding var active: ActiveContext?
    let user: ContextUser?
    let notificationCounts: [String: Int]
    let onSwitch: (ActiveContext) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var switchingContextKey: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        // Active context header
                        if let currentActive = active {
                            activeHeader(currentActive)
                        }

                        Divider().background(C.border)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, C.pagePad)
                                .padding(.vertical, 10)
                        }

                        // Context list
                        LazyVStack(spacing: 0) {
                            ForEach(contexts, id: \.switcherKey) { ctx in
                                ContextRow(
                                    ctx: ctx,
                                    user: user,
                                    isActive: ctx.id == active?.id && ctx.type == active?.type,
                                    isSwitching: switchingContextKey == ctx.switcherKey,
                                    unreadCount: unreadNotificationCount(for: ctx)
                                ) {
                                    Task { await switchTo(ctx) }
                                }
                                Divider().background(C.border)
                                    .padding(.leading, C.pagePad + 40)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Switch Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
                }
            }
        }
    }

    // MARK: - Active context header

    private func activeHeader(_ ctx: ActiveContext) -> some View {
        HStack(spacing: 12) {
            ContextAvatar(ctx: ctx, user: user, size: 44)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active context")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                Text(ctx.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                Text(ctx.type.capitalized)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 16)
    }

    // MARK: - Icon

    @ViewBuilder
    private func contextIcon(_ type: String) -> some View {
        let (iconName, color): (String, Color) = {
            switch type {
            case "admin":   return ("shield.fill",       Color(hex: "#EF4444"))
            case "network": return ("building.2.fill",   Color(hex: "#F59E0B"))
            case "channel": return ("play.rectangle.fill", C.watch)
            default:        return ("person.fill",        Color(hex: "#10B981"))
            }
        }()
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Switch

    private func switchTo(_ ctx: ActiveContext) async {
        guard switchingContextKey == nil else { return }
        switchingContextKey = ctx.switcherKey
        errorMessage = nil
        defer { switchingContextKey = nil }

        do {
            let response = try await APIClient.shared.switchContext(ctx)
            guard response.ok else {
                throw ContextSwitchError.failed
            }

            let confirmedContext = response.context ?? ctx
            if let contextsResponse = try? await APIClient.shared.fetchContexts() {
                contexts = contextsResponse.contexts
                active = context(contextsResponse.active, matches: confirmedContext)
                    ? contextsResponse.active
                    : contexts.first(where: { context($0, matches: confirmedContext) }) ?? confirmedContext
            } else {
                active = confirmedContext
            }

            let switchedContext = active ?? confirmedContext
            UploadOptionsCache.clear()
            UploadOptionsCache.warmContexts()
            C.lightHaptic()
            onSwitch(switchedContext)
            NotificationCenter.default.post(name: .appContextDidChange, object: switchedContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func context(_ lhs: ActiveContext, matches rhs: ActiveContext) -> Bool {
        lhs.type == rhs.type && lhs.id == rhs.id
    }

    private func unreadNotificationCount(for ctx: ActiveContext) -> Int {
        let directKeys = ctx.notificationCountKeys
        for key in directKeys {
            if let value = notificationCounts[key], value > 0 {
                return value
            }
        }

        if let active, context(ctx, matches: active) {
            for key in ["unread", "unreadCount", "unread_count", "totalUnread", "total_unread", "notificationsUnread", "notifications_unread"] {
                if let value = notificationCounts[key], value > 0 {
                    return value
                }
            }
        }

        return 0
    }
}

private extension ActiveContext {
    var switcherKey: String {
        [type, id, channelId ?? ""].joined(separator: ":")
    }

    var notificationCountKeys: [String] {
        var keys = [
            switcherKey,
            "\(type):\(id)",
            "\(type)_\(id)",
            "\(type).\(id)",
            id
        ]

        if let channelId, channelId != id {
            keys.append(contentsOf: [
                "\(type):\(channelId)",
                "\(type)_\(channelId)",
                "\(type).\(channelId)",
                channelId
            ])
        }

        return keys
    }
}

// MARK: - Context avatar

private struct ContextAvatar: View {
    let ctx: ActiveContext
    let user: ContextUser?
    let size: CGFloat

    private var imageURL: URL? {
        if let url = C.mediaURL(ctx.avatarUrl ?? ctx.image) {
            return url
        }
        if ctx.type == "user", let url = C.mediaURL(user?.image) {
            return url
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let imageURL {
                CachedRemoteImage(
                    url: imageURL,
                    targetSize: CGSize(width: size, height: size)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackIcon
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: ctx.type == "channel" || ctx.type == "user" ? size / 2 : 10))
    }

    private var fallbackIcon: some View {
        let color: Color = {
            switch ctx.type {
            case "admin": return Color(hex: "#EF4444")
            case "network": return Color(hex: "#F59E0B")
            case "show": return Color(hex: "#A780D7")
            default: return C.watch
            }
        }()

        let initials = ctx.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: max(11, size * 0.34), weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12))
    }
}

// MARK: - Context row

private struct ContextRow: View {
    let ctx: ActiveContext
    let user: ContextUser?
    let isActive: Bool
    let isSwitching: Bool
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ContextAvatar(ctx: ctx, user: user, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.name)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(C.text)
                    Text(typeLabel(ctx.type))
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }

                Spacer()

                if isSwitching {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(C.watch)
                } else {
                    if unreadCount > 0 {
                        unreadBadge(unreadCount)
                    }

                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(C.watch)
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 14)
        }
        .disabled(isSwitching)
    }

    private func unreadBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .monospacedDigit()
            .padding(.horizontal, count > 9 ? 7 : 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(C.watch, in: Capsule())
            .accessibilityLabel("\(count) unread notifications")
    }

    @ViewBuilder
    private func contextIcon(_ type: String) -> some View {
        let (iconName, color): (String, Color) = {
            switch type {
            case "admin":   return ("shield.fill",         Color(hex: "#EF4444"))
            case "network": return ("building.2.fill",     Color(hex: "#F59E0B"))
            case "channel": return ("play.rectangle.fill", Color(hex: "#0EA5E9"))
            default:        return ("person.fill",          Color(hex: "#10B981"))
            }
        }()
        Image(systemName: iconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "admin":   return "System Admin"
        case "network": return "Network"
        case "channel": return "Channel"
        default:        return "Viewer"
        }
    }
}

private enum ContextSwitchError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Could not switch context. Try again."
    }
}
