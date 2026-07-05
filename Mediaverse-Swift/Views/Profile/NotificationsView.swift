import SwiftUI

/// Notifications inbox — scoped to active context, marks all read on appear.
/// Mirrors /src/app/notifications/page.tsx
struct NotificationsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var notifs     = [AppNotification]()
    @State private var isLoading  = true
    @State private var route: AppRoute?

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
            }
            .navigationDestination(item: $route) { route in
                routeDestination(route)
            }
            .task { await load() }
        }
    }

    private var notifList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
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
            .padding(C.pagePad)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("🔔").font(.system(size: 48))
            Text("No notifications yet")
                .font(.headline).foregroundStyle(C.text)
            Text("Follow channels and shows to get notified about new content.")
                .font(.subheadline).foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        notifs = (try? await APIClient.shared.fetchNotifications()) ?? []
        // Mark all as read after displaying
        if notifs.contains(where: { !$0.read }) {
            try? await APIClient.shared.markNotificationsRead()
        }
        isLoading = false
    }

    private func open(_ notif: AppNotification) {
        guard let link = notif.linkUrl, !link.isEmpty else { return }
        if let parsed = route(for: link) {
            route = parsed
            return
        }
        if let url = URL(string: link) {
            openURL(url)
        }
    }

    private func route(for link: String) -> AppRoute? {
        let path: String
        if let url = URL(string: link), let host = url.host, !host.isEmpty {
            path = url.path
        } else {
            path = link
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count >= 3, parts[0] == "watch", parts[1] == "episode" { return .episode(parts[2]) }
        if parts.count >= 2, parts[0] == "watch" { return .video(parts[1]) }
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

// MARK: - Row

private struct NotifRow: View {
    let notif: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: iconFor(notif.type))
                .font(.system(size: 16))
                .foregroundStyle(C.watch)
                .frame(width: 36, height: 36)
                .background(C.watch.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(notif.title)
                    .font(.subheadline.weight(notif.read ? .regular : .semibold))
                    .foregroundStyle(C.text)
                Text(notif.message)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(3)
                Text(relativeTime(notif.createdAt))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.25))
            }

            Spacer()

            if !notif.read {
                Circle()
                    .fill(C.watch)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
            }
        }
        .padding(14)
        .background(notif.read ? C.surface.opacity(0.6) : C.surface)
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: C.cardRadius)
                .stroke(notif.read ? C.border.opacity(0.5) : C.border, lineWidth: 1)
        }
        .overlay(alignment: .trailing) {
            if notif.linkUrl != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(C.textMuted.opacity(0.6))
                    .padding(.trailing, 10)
            }
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "follow":   return "person.badge.plus"
        case "comment":  return "bubble.left"
        case "upload":   return "arrow.up.circle"
        case "partner":  return "star"
        default:         return "bell"
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60        { return "just now" }
        if secs < 3600      { return "\(secs / 60)m ago" }
        if secs < 86400     { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
