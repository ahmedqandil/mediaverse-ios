import SwiftUI

/// Watch History screen — mirrors /history page on web.
///
/// Layout:
///   - Unauthenticated → clock icon + "Sign in…" message
///   - Loading         → 3 skeleton rows
///   - Empty           → clock icon + "No watch history yet" + Explore button
///   - Loaded          → scrollable list of horizontal video/episode cards
///
/// Each row is a NavigationLink → VideoWatchView or EpisodeWatchView.
/// "Clear all" button in toolbar shows a confirmation before deleting.
struct WatchHistoryView: View {

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var items:            [HistoryItem] = []
    @State private var loading           = true
    @State private var showClearConfirm  = false

    // Thumbnail dimensions matching EpisodeHistoryCard on web (w-36 × aspect-video)
    private let thumbW: CGFloat = 144
    private var thumbH: CGFloat { (thumbW * 9 / 16).rounded() }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if !auth.isAuthenticated {
                unauthState
            } else if loading {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        skeletonRows
                    }
                    .padding(.top, 8)
                }
            } else if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            historyRow(item)
                            Divider()
                                .background(C.border)
                                .padding(.leading, C.pagePad + thumbW + 12)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Watch History")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !loading && !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all") {
                        showClearConfirm = true
                    }
                    .foregroundStyle(Color.red)
                }
            }
        }
        .confirmationDialog(
            "Clear all watch history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .task {
            await load()
        }
    }

    // MARK: - Row dispatcher

    @ViewBuilder
    private func historyRow(_ item: HistoryItem) -> some View {
        if let v = item.video {
            NavigationLink(value: AppRoute.media(id: v.id, type: v.type, channelId: v.channel?.id)) {
                videoCard(v, watchedAt: item.watchedAt)
            }
            .buttonStyle(.plain)
        } else if let ep = item.episode {
            NavigationLink(value: AppRoute.episode(ep.id)) {
                episodeCard(ep, watchedAt: item.watchedAt)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Video card (horizontal)

    private func videoCard(_ v: HistoryVideoStub, watchedAt: String) -> some View {
        HStack(alignment: .top, spacing: 12) {

            // Thumbnail
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: C.mediaURL(v.thumbnailUrl)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: thumbW, height: thumbH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let dur = v.duration {
                    durationBadge(dur)
                }
            }
            .frame(width: thumbW, height: thumbH)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(v.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let ch = v.channel {
                    Text(ch.name)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }

                Text(timeAgo(watchedAt))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 12)
    }

    // MARK: - Episode card (horizontal)

    private func episodeCard(_ ep: HistoryEpisodeStub, watchedAt: String) -> some View {
        HStack(alignment: .top, spacing: 12) {

            // Thumbnail — episode thumbnail or show cover as fallback
            let thumbURL = ep.thumbnailUrl ?? ep.season?.show?.coverUrl

            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: C.mediaURL(thumbURL)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: thumbW, height: thumbH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Text("Episode")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }

                if let dur = ep.duration {
                    durationBadge(dur)
                }
            }
            .frame(width: thumbW, height: thumbH)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                // Show title (bold) — primary identifier
                if let showTitle = ep.season?.show?.title {
                    Text(showTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // Episode title (secondary)
                Text(ep.title)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)

                // S/E label
                Text(seLabel(ep))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)

                Text(timeAgo(watchedAt))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 12)
    }

    // MARK: - Duration badge (shared)

    @ViewBuilder
    private func durationBadge(_ secs: Double) -> some View {
        let h   = Int(secs) / 3600
        let m   = (Int(secs) % 3600) / 60
        let s   = Int(secs) % 60
        let lbl = h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"

        Text(lbl)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }

    // MARK: - Skeleton loading rows

    @ViewBuilder
    private var skeletonRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: thumbW, height: thumbH)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 100, height: 11)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 64, height: 11)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 12)

            Divider()
                .background(C.border)
                .padding(.leading, C.pagePad + thumbW + 12)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 56))
                .foregroundStyle(C.textMuted)

            Text("No watch history yet")
                .font(.title3.bold())
                .foregroundStyle(C.text)

            Text("Videos and episodes you watch will appear here.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                dismiss()
            } label: {
                Text("Explore content")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.bg)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(C.watch)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unauthenticated state

    private var unauthState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 56))
                .foregroundStyle(C.textMuted)

            Text("Sign in to view your history")
                .font(.title3.bold())
                .foregroundStyle(C.text)

            Text("Your watch history will appear here once you sign in.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func load() async {
        loading = true
        items = (try? await APIClient.shared.fetchHistory()) ?? []
        loading = false
    }

    private func clearAll() async {
        try? await APIClient.shared.clearHistory()
        withAnimation { items = [] }
    }

    // MARK: - Helpers

    private func seLabel(_ ep: HistoryEpisodeStub) -> String {
        let sn = ep.season?.seasonNumber ?? 1
        return "S\(sn) · E\(ep.episodeNumber)"
    }

    /// Relative time string matching web's formatDistanceToNow behaviour.
    private func timeAgo(_ isoString: String) -> String {
        let fISO = ISO8601DateFormatter()
        fISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fISO.date(from: isoString)
            ?? ISO8601DateFormatter().date(from: isoString)

        guard let d = date else { return "" }

        let secs = max(0, -d.timeIntervalSinceNow)
        if secs < 60         { return "just now" }
        if secs < 3_600      { return "\(Int(secs / 60))m ago" }
        if secs < 86_400     { return "\(Int(secs / 3_600))h ago" }
        if secs < 86_400 * 7 { return "\(Int(secs / 86_400))d ago" }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: d)
    }
}
