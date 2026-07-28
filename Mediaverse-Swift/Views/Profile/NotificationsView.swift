import SwiftUI

struct NotificationPreferences: Decodable, Equatable {
    var notifyComments: Bool
    var notifyLikes: Bool
    var notifyReplies: Bool
    var notifyNewContent: Bool
    var notifyMentions: Bool
    var notifyVibeActivity: Bool
    var emailNewContent: Bool
    var emailComments: Bool
    var emailMarketing: Bool
}

private struct NotificationPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: NotificationPreferences?
    @State private var saving = Set<NotificationPreferenceField>()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preferences {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            preferenceSection(
                                "IN-APP NOTIFICATIONS",
                                fields: [
                                    (.notifyComments, "Comments on my content", "When someone comments on your videos or Ripples"),
                                    (.notifyLikes, "Energy and comment likes", "When someone adds Energy or likes your comment"),
                                    (.notifyReplies, "Replies to my comments", "When someone replies to a comment you left"),
                                    (.notifyNewContent, "New content from follows", "Uploads and Ripples from people, Shows, Channels, and Vibes you follow"),
                                    (.notifyMentions, "Mentions", "When someone mentions you in a Ripple or comment"),
                                    (.notifyVibeActivity, "Vibe activity", "Invitations, moderation updates, and when a moderator pins your Ripple")
                                ],
                                preferences: preferences
                            )
                            preferenceSection(
                                "EMAIL NOTIFICATIONS",
                                fields: [
                                    (.emailNewContent, "New content digest", "A summary of new content from your follows"),
                                    (.emailComments, "Comments and replies", "Email when someone engages with your content"),
                                    (.emailMarketing, "Westreem updates", "Product news and announcements")
                                ],
                                preferences: preferences
                            )
                            notificationInheritanceGuide(vibeActivityEnabled: preferences.notifyVibeActivity)
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(C.pagePad)
                    }
                } else {
                    ProgressView("Loading preferences…")
                        .tint(C.watch)
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Notification Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
                }
            }
            .task { await load() }
        }
    }

    private func notificationInheritanceGuide(vibeActivityEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VIBE, WAVE & EVENT DELIVERY")
                .font(.caption2.weight(.bold))
                .foregroundStyle(C.textMuted)
            VStack(alignment: .leading, spacing: 14) {
                inheritanceRow(
                    icon: "person.3",
                    title: "Vibes",
                    detail: vibeActivityEnabled
                        ? "Vibe activity is enabled by your global setting above."
                        : "Vibe activity is muted by your global setting above."
                )
                Divider().overlay(C.borderSubtle)
                inheritanceRow(
                    icon: "water.waves",
                    title: "Waves",
                    detail: "Each Wave uses its Vibe setting by default. A Wave’s settings can override it with All activity, Mentions only, or Muted."
                )
                Divider().overlay(C.borderSubtle)
                inheritanceRow(
                    icon: "calendar",
                    title: "Events",
                    detail: "Events inherit Vibe activity. Scheduled Event pages also support explicit 15-minute, 1-hour, and 1-day push reminders."
                )
            }
            .padding(14)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        }
    }

    private func inheritanceRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(C.watch)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private func preferenceSection(
        _ title: String,
        fields: [(NotificationPreferenceField, String, String)],
        preferences: NotificationPreferences
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(C.textMuted)
            VStack(spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.0) { index, field in
                    Toggle(
                        isOn: Binding(
                            get: { value(of: field.0, in: preferences) },
                            set: { enabled in
                                Task { await update(field.0, enabled: enabled) }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.1)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(C.text)
                            Text(field.2)
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    .tint(C.watch)
                    .disabled(saving.contains(field.0))
                    .padding(.vertical, 12)
                    if index < fields.count - 1 {
                        Divider().overlay(C.borderSubtle)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.borderSubtle))
        }
    }

    @MainActor
    private func load() async {
        do {
            preferences = try await APIClient.shared.fetchNotificationPreferences()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func update(_ field: NotificationPreferenceField, enabled: Bool) async {
        guard !saving.contains(field) else { return }
        saving.insert(field)
        errorMessage = nil
        do {
            preferences = try await APIClient.shared.updateNotificationPreference(field, enabled: enabled)
        } catch {
            errorMessage = "Could not save notification preferences."
        }
        saving.remove(field)
    }

    private func value(
        of field: NotificationPreferenceField,
        in preferences: NotificationPreferences
    ) -> Bool {
        switch field {
        case .notifyComments: preferences.notifyComments
        case .notifyLikes: preferences.notifyLikes
        case .notifyReplies: preferences.notifyReplies
        case .notifyNewContent: preferences.notifyNewContent
        case .notifyMentions: preferences.notifyMentions
        case .notifyVibeActivity: preferences.notifyVibeActivity
        case .emailNewContent: preferences.emailNewContent
        case .emailComments: preferences.emailComments
        case .emailMarketing: preferences.emailMarketing
        }
    }
}

enum NotificationPreferenceField: String, CaseIterable {
    case notifyComments
    case notifyLikes
    case notifyReplies
    case notifyNewContent
    case notifyMentions
    case notifyVibeActivity
    case emailNewContent
    case emailComments
    case emailMarketing
}

/// Notifications inbox scoped to the active context.
struct NotificationsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    let onUnreadCountChange: ((Int) -> Void)?

    @State private var notifs = [AppNotification]()
    @State private var isLoading = true
    @State private var isMarkingRead = false
    @State private var route: AppRoute?
    @State private var showsPreferences = false
    @State private var notificationMutationGeneration = 0

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
                    HStack(spacing: 14) {
                        Button {
                            showsPreferences = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Notification preferences")

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
            }
            .navigationDestination(item: $route) { route in
                routeDestination(route)
            }
            .task { await load() }
            .sheet(isPresented: $showsPreferences) {
                NotificationPreferencesView()
            }
        }
    }

    private var notifList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inboxHeader

                LazyVStack(spacing: 10) {
                    ForEach(notifs) { notif in
                        Button {
                            Task { await open(notif) }
                        } label: {
                            NotifRow(notif: notif)
                        }
                        .buttonStyle(.plain)
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
        let generation = notificationMutationGeneration
        isLoading = true
        let refreshed = (try? await APIClient.shared.fetchNotifications()) ?? []
        guard generation == notificationMutationGeneration, !Task.isCancelled else {
            if generation != notificationMutationGeneration { isLoading = false }
            return
        }
        notifs = refreshed
        publishUnreadCount(unreadCount)
        isLoading = false
    }

    private func markAllAsRead() async {
        guard hasUnreadNotifications, !isMarkingRead else { return }
        notificationMutationGeneration &+= 1
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
                    contextId: notif.contextId,
                    contentType: notif.contentType,
                    videoId: notif.videoId,
                    shortId: notif.shortId,
                    episodeId: notif.episodeId,
                    episodeNumber: notif.episodeNumber,
                    showId: notif.showId,
                    microdramaId: notif.microdramaId,
                    channelId: notif.channelId,
                    channelHandle: notif.channelHandle,
                    playlistId: notif.playlistId,
                    collectionId: notif.collectionId
                )
            }
            publishUnreadCount(0)
            if let refreshed = try? await APIClient.shared.fetchNotifications() {
                notifs = refreshed
                publishUnreadCount(refreshed.filter { !$0.read }.count)
            }
        } catch {
            // Keep unread state visible if the server update fails.
        }
        isMarkingRead = false
    }

    private func open(_ notif: AppNotification) async {
        await markAsReadIfNeeded(notif)
        if let parsed = route(for: notif) {
            open(parsed)
            return
        }
        guard let link = notif.linkUrl, !link.isEmpty else { return }
        if let parsed = AppRoute.route(link: link, notificationType: notif.contentType ?? notif.type) {
            open(parsed)
            return
        }
        if let url = URL(string: link) {
            openTrustedURL(url)
        }
    }

    private func openTrustedURL(_ url: URL) {
        if InAppBrowserManager.canDisplayInApp(url) {
            inAppBrowser.open(url)
        } else {
            openURL(url)
        }
    }

    private func open(_ parsed: AppRoute) {
        if case .short = parsed {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                NotificationCenter.default.post(name: .pushRouteRequested, object: parsed)
            }
        } else {
            route = parsed
        }
    }

    private func markAsReadIfNeeded(_ notif: AppNotification) async {
        guard !notif.read else { return }
        notificationMutationGeneration &+= 1
        do {
            try await APIClient.shared.markNotificationsRead()
            notifs = notifs.map { notification($0, read: true) }
            publishUnreadCount(0)
        } catch {
            publishUnreadCount(unreadCount)
        }
    }

    private func publishUnreadCount(_ count: Int) {
        onUnreadCountChange?(count)
        NotificationCenter.default.post(name: .notificationCountsDidChange, object: count)
    }

    private func setNotification(_ id: String, read: Bool) {
        notifs = notifs.map { notif in
            guard notif.id == id else { return notif }
            return notification(notif, read: read)
        }
    }

    private func notification(_ notif: AppNotification, read: Bool) -> AppNotification {
        AppNotification(
            id: notif.id,
            type: notif.type,
            title: notif.title,
            message: notif.message,
            linkUrl: notif.linkUrl,
            imageUrl: notif.imageUrl,
            read: read,
            createdAt: notif.createdAt,
            contextType: notif.contextType,
            contextId: notif.contextId,
            contentType: notif.contentType,
            videoId: notif.videoId,
            shortId: notif.shortId,
            episodeId: notif.episodeId,
            episodeNumber: notif.episodeNumber,
            showId: notif.showId,
            microdramaId: notif.microdramaId,
            channelId: notif.channelId,
            channelHandle: notif.channelHandle,
            playlistId: notif.playlistId,
            collectionId: notif.collectionId
        )
    }

    private func route(for notif: AppNotification) -> AppRoute? {
        notif.appRoute
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .video(let id): VideoWatchView(videoId: id)
        case .short(let id, let showId, let channelId): ShortsView(initialShortId: id, contextShowId: showId, contextChannelId: channelId, showsDismissControls: true)
        case .episode(let id): EpisodeWatchView(episodeId: id)
        case .channel(let id): ChannelView(handle: id)
        case .show(let id): ShowView(showId: id)
        case .showSeason(let showId, let seasonId): ShowView(showId: showId, initialSeasonId: seasonId)
        case .showAccess(let showId, let productId, let intent, let handoffId):
            ShowView(showId: showId, handoffProductId: productId, handoffIntent: intent, handoffPublicId: handoffId)
        case .handoff(let id): HandoffResolverView(publicId: id)
        case .playlist(let id): PlaylistDetailView(playlistId: id)
        case .collection(let id): CollectionDetailView(collectionId: id)
        case .microdramaShow(let id): MicrodramaShowView(showId: id)
        case .microdramaWatch(let id): MicrodramaWatchView(showId: id)
        case .microdramaWatchEp(let id, let episodeNumber): MicrodramaWatchView(showId: id, startEpisodeNumber: episodeNumber)
        case .vibe(let slug): VibeDetailView(slug: slug)
        case .vibeWave(let vibeSlug, let waveSlug): VibeDetailView(slug: vibeSlug, initialWaveSlug: waveSlug)
        case .vibeManagement(let slug, let tab): VibeDetailView(slug: slug, initialManagementTab: tab)
        case .vibeInvite(let token): VibeInviteAcceptView(token: token)
        case .event(let slug): VibeEventDetailView(slug: slug)
        case .eventInvite(let token): VibeEventInviteView(token: token)
        case .ripple(let postId): RippleDetailView(postId: postId)
        case .flash(let storyId): FlashDeepLinkView(storyId: storyId)
        case .atmo(let handle): AtmoProfileView(handle: handle)
        case .search(let query): SearchView(initialQuery: query)
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

                    if notif.appRoute != nil || notif.linkUrl != nil {
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
            if let url = C.mediaURL(notif.imageUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 42, height: 42)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    iconFallback
                }
            } else {
                iconFallback
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(notif.read ? C.border.opacity(0.45) : C.watch.opacity(0.24), lineWidth: 1)
        }
    }

    private var iconFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(notif.read ? Color.white.opacity(0.07) : C.watch.opacity(0.14))
            Image(systemName: iconFor(notif.type))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(notif.read ? C.textMuted : C.watch)
        }
    }

    private func iconFor(_ type: String) -> String {
        // Keys are the ACTUAL server notification types. (Previously these were short
        // aliases like "comment"/"like" that never matched, so everything showed a bell.)
        switch type.lowercased() {
        case "new_comment", "comment_reply", "comment_removed",
             "post_comment", "post_comment_reply", "comment",
             "ripple_comment", "ripple_reply":
            return "bubble.left.fill"
        case "comment_like", "post_comment_liked", "post_liked", "story_like", "like":
            return "heart.fill"
        case "ripple_energy", "ripple_photo_energy", "flash_energy":
            return "bolt.fill"
        case "ripple_echo":
            return "wave.3.right"
        case "mention", "story_mention", "ripple_mention":
            return "at"
        case "new_follower", "following", "follow", "vibe_follow":
            return "person.badge.plus"
        case "new_episode", "new_video", "vibe_new_ripple":
            return "play.rectangle.fill"
        case "vibe_join_request", "vibe_join_decision", "vibe_invite":
            return "person.2.fill"
        case "vibe_moderation":
            return "shield.fill"
        case "ripple_pinned", "ripple_unpinned":
            return "pin.fill"
        case "vibe_affiliation_request", "vibe_affiliation_approved",
             "vibe_affiliation_rejected", "vibe_affiliation_revoked",
             "vibe_affiliation_cancelled":
            return "link"
        case "upload_complete", "upload":
            return "arrow.up.circle.fill"
        case "partner_approved":
            return "checkmark.seal.fill"
        case "partner_rejected":
            return "xmark.seal.fill"
        case "partner_request", "partner":
            return "star.fill"
        case "network_invite":
            return "envelope.fill"
        case "device_handoff":
            return "tv.fill"
        case "info":
            return "info.circle.fill"
        default:
            return "bell.fill"
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "new_comment", "post_comment", "ripple_comment": return "Comment"
        case "comment_reply", "post_comment_reply", "ripple_reply": return "Reply"
        case "comment_like", "post_comment_liked":     return "Like"
        case "post_liked":                             return "Post Like"
        case "story_like":                             return "Flash Like"
        case "ripple_energy":                          return "Ripple Energy"
        case "ripple_photo_energy":                    return "Photo Energy"
        case "flash_energy":                           return "Flash Energy"
        case "ripple_echo":                            return "Echo"
        case "mention", "story_mention", "ripple_mention": return "Mention"
        case "comment_removed":                        return "Moderation"
        case "new_follower", "following", "vibe_follow": return "Follower"
        case "vibe_join_request":                      return "Join Request"
        case "vibe_join_decision":                     return "Membership"
        case "vibe_invite":                            return "Vibe Invite"
        case "vibe_moderation":                        return "Vibe Moderation"
        case "ripple_pinned":                          return "Pinned Ripple"
        case "ripple_unpinned":                        return "Unpinned Ripple"
        case "vibe_new_ripple":                        return "New Ripple"
        case "vibe_affiliation_request":               return "Affiliation Request"
        case "vibe_affiliation_approved":              return "Affiliation Approved"
        case "vibe_affiliation_rejected":              return "Affiliation Rejected"
        case "vibe_affiliation_revoked":               return "Affiliation Revoked"
        case "vibe_affiliation_cancelled":             return "Affiliation Cancelled"
        case "new_episode":                            return "New Episode"
        case "new_video":                              return "New Video"
        case "upload_complete":                        return "Upload Ready"
        case "partner_request":                        return "Partner Request"
        case "partner_approved":                       return "Partner Approved"
        case "partner_rejected":                       return "Partner Rejected"
        case "network_invite":                         return "Network Invite"
        case "device_handoff":                         return "Device"
        case "info":                                   return "Info"
        default:
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Update" }
            return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
