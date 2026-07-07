import SwiftUI

/// Notifications inbox scoped to the active context.
struct NotificationsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let onUnreadCountChange: ((Int) -> Void)?

    @State private var notifs = [AppNotification]()
    @State private var isLoading = true
    @State private var isMarkingRead = false
    @State private var route: AppRoute?

    init(onUnreadCountChange: ((Int) -> Void)? = nil) {
        self.onUnreadCountChange = onUnreadCountChange
    }

    private var unreadCount: Int {
        notifs.filter { !$0.read }.count
    }

    private var hasUnreadNotifications: Bool {
        unreadCount > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(C.watch)
                } else if notifs.isEmpty {
                    emptyState
                } else {
                    notifList
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if hasUnreadNotifications {
                        Button {
                            Task { await markAllAsRead() }
                        } label: {
                            if isMarkingRead {
                                ProgressView()
                                    .tint(C.watch)
                            } else {
                                Text("Mark read")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.watch)
                        .disabled(isMarkingRead)
                    }
                }
            }
            .navigationDestination(item: $route) { route in
                routeDestination(route)
            }
            .task { await load() }
        }
    }

    private var notifList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inboxHeader

                LazyVStack(spacing: 10) {
                    ForEach(notifs) { notif in
                        Button {
                            open(notif)
                        } label: {
                            NotifRow(notif: notif)
                        }
                        .buttonStyle(.plain)
                        .disabled(notif.linkUrl == nil)
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 14)
        }
    }

    private var inboxHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(C.watch.opacity(0.14))
                MediaverseIcon(name: "notification", fallbackSystemName: "bell")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(C.watch)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(hasUnreadNotifications ? "\(unreadCount) unread" : "All caught up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("Updates from the channels, shows, and activity you follow.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(C.border, lineWidth: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(C.watch.opacity(0.12))
                    .frame(width: 72, height: 72)
                MediaverseIcon(name: "notification", fallbackSystemName: "bell")
                    .frame(width: 30, height: 30)
                    .foregroundStyle(C.watch)
            }
            Text("No notifications yet")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("Follow channels and shows to get notified about new content.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        notifs = (try? await APIClient.shared.fetchNotifications()) ?? []
        onUnreadCountChange?(unreadCount)
        isLoading = false
    }

    private func markAllAsRead() async {
        guard hasUnreadNotifications, !isMarkingRead else { return }
        isMarkingRead = true
        do {
            try await APIClient.shared.markNotificationsRead()
            notifs = notifs.map { notif in
                AppNotification(
                    id: notif.id,
                    type: notif.type,
                    title: notif.title,
                    message: notif.message,
                    linkUrl: notif.linkUrl,
                    imageUrl: notif.imageUrl,
                    read: true,
                    createdAt: notif.createdAt,
                    contextType: notif.contextType,
                    contextId: notif.contextId
                )
            }
            onUnreadCountChange?(0)
            if let refreshed = try? await APIClient.shared.fetchNotifications() {
                notifs = refreshed
                onUnreadCountChange?(refreshed.filter { !$0.read }.count)
            }
        } catch {
            // Keep unread state visible if the server update fails.
        }
        isMarkingRead = false
    }

    private func open(_ notif: AppNotification) {
        guard let link = notif.linkUrl, !link.isEmpty else { return }
        if let parsed = route(for: notif) {
            route = parsed
            return
        }
        if let url = URL(string: link) {
            openURL(url)
        }
    }

    private func route(for notif: AppNotification) -> AppRoute? {
        guard let link = notif.linkUrl else { return nil }
        let path: String
        var queryType: String?
        if let url = URL(string: link), let host = url.host, !host.isEmpty {
            path = url.path
            queryType = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "type" || $0.name == "contentType" }?
                .value
        } else {
            let components = URLComponents(string: link)
            path = components?.path ?? link
            queryType = components?
                .queryItems?
                .first { $0.name == "type" || $0.name == "contentType" }?
                .value
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        let notificationLooksLikeShort = notif.type.lowercased().contains("short") || queryType?.lowercased() == "short"
        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" { return .episode(parts[2]) }
        if parts.count >= 2, parts[0] == "watch" {
            return notificationLooksLikeShort ? .short(parts[1], showId: nil, channelId: nil) : .video(parts[1])
        }
        if parts.count >= 2, parts[0] == "shorts" { return .short(parts[1], showId: nil, channelId: nil) }
        if parts.count >= 2, parts[0] == "short" { return .short(parts[1], showId: nil, channelId: nil) }
        if parts.count >= 2, parts[0] == "shows" { return .show(parts[1]) }
        if parts.count >= 2, parts[0] == "channel" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "channels" { return .channel(parts[1]) }
        if parts.count >= 2, parts[0] == "playlist" { return .playlist(parts[1]) }
        if parts.count >= 2, parts[0] == "playlists" { return .playlist(parts[1]) }
        if parts.count >= 2, parts[0] == "collections" { return .collection(parts[1]) }
        if parts.count >= 2, parts[0] == "microdramas" { return .microdramaShow(parts[1]) }
        return nil
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id): VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId)
        case .episode(let id): EpisodeWatchView(episodeId: id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        }
    }
}

private struct NotifRow: View {
    let notif: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notif.title)
                        .font(.system(size: 14, weight: notif.read ? .semibold : .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)

                    Spacer(minLength: 6)

                    Text(relativeTime(notif.createdAt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.textMuted.opacity(0.78))
                        .lineLimit(1)
                }

                Text(notif.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(typeLabel(notif.type))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(notif.read ? C.textMuted : C.watch)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background((notif.read ? Color.white.opacity(0.06) : C.watch.opacity(0.12)))
                        .clipShape(Capsule())

                    if notif.linkUrl != nil {
                        MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                            .frame(width: 8, height: 8)
                            .foregroundStyle(C.textMuted.opacity(0.7))
                    }
                }
            }
        }
        .padding(14)
        .background(notif.read ? C.surface.opacity(0.58) : C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(notif.read ? C.border.opacity(0.5) : C.watch.opacity(0.30), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if !notif.read {
                Circle()
                    .fill(C.watch)
                    .frame(width: 8, height: 8)
                    .padding(10)
            }
        }
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(notif.read ? Color.white.opacity(0.07) : C.watch.opacity(0.14))
            Image(systemName: iconFor(notif.type))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(notif.read ? C.textMuted : C.watch)
        }
        .frame(width: 42, height: 42)
    }

    private func iconFor(_ type: String) -> String {
        switch type.lowercased() {
        case "follow": return "person.badge.plus"
        case "comment": return "bubble.left"
        case "upload": return "arrow.up.circle"
        case "partner": return "star"
        case "like": return "heart"
        default: return "bell"
        }
    }

    private func typeLabel(_ type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Update" }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}
