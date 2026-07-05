import SwiftUI

/// Channels browse page.
/// Mirrors the mobile web /channels route: search, inactive filtering, full channel cards.
struct ChannelsBrowseView: View {

    @State private var channels = [ChannelBrowseCard]()
    @State private var query = ""
    @State private var isLoading = true

    private var filteredChannels: [ChannelBrowseCard] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return channels.filter { channel in
            channel.status != "inactive" && (
                q.isEmpty ||
                channel.name.lowercased().contains(q) ||
                channel.handle.lowercased().contains(q)
            )
        }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                searchHeader

                if isLoading {
                    loadingGrid
                } else if filteredChannels.isEmpty {
                    emptyState
                } else {
                    channelGrid
                }
            }
        }
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(C.textMuted)

            TextField("Search channels...", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(C.text)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(C.elevated)
        .clipShape(Capsule())
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 12)
        .background(C.surface)
    }

    private var channelGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 14) {
                ForEach(filteredChannels) { channel in
                    ChannelBrowseFullCard(channel: channel)
                }
            }
            .padding(C.pagePad)
        }
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 14) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: C.cardRadius - 2)
                            .fill(Color.white.opacity(0.05))
                            .frame(height: 96)
                        RoundedRectangle(cornerRadius: C.cardRadius - 2)
                            .fill(C.surface)
                            .frame(height: 116)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: C.cardRadius)
                            .stroke(C.border, lineWidth: 1)
                    }
                    .shimmering()
                }
            }
            .padding(C.pagePad)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.person.crop")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text(query.isEmpty ? "No channels yet" : "No channels match your search")
                .font(.headline)
                .foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, C.pagePad)
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            channels = try await APIClient.shared.fetchChannels()
        } catch {
            channels = []
        }
        isLoading = false
    }
}

private struct ChannelBrowseFullCard: View {
    let channel: ChannelBrowseCard

    @EnvironmentObject private var auth: AuthManager
    @State private var followStatus: FollowStatus?
    @State private var isTogglingFollow = false

    private var routeHandle: String { channel.handle }
    private var isFollowing: Bool { followStatus?.subscribed == true }
    private var followerCount: Int { followStatus?.count ?? channel._count?.followers ?? 0 }
    private var videoCount: Int { channel._count?.videos ?? 0 }
    private var accent: Color { C.watch }

    var body: some View {
        NavigationLink(value: AppRoute.channel(routeHandle)) {
            VStack(spacing: 0) {
                banner
                bodyContent
            }
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: C.cardRadius)
                    .stroke(C.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .task { await loadFollowStatus() }
    }

    private var banner: some View {
        ZStack {
            if let bannerUrl = C.mediaURL(channel.bannerUrl) {
                AsyncImage(url: bannerUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackBanner
                }
            } else {
                fallbackBanner
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(Color.black.opacity(channel.bannerUrl == nil ? 0 : 0.32))
    }

    private var fallbackBanner: some View {
        LinearGradient(
            colors: [accent.opacity(0.18), accent.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                avatar
                    .offset(y: -24)
                    .padding(.bottom, -24)

                Spacer()

                if auth.isAuthenticated {
                    followButton
                }
            }

            HStack(spacing: 5) {
                Text(channel.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)

                if channel.verified {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }

            Text("@\(channel.handle)")
                .font(.caption2)
                .foregroundStyle(C.textMuted.opacity(0.8))
                .lineLimit(1)

            if let description = channel.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("\(formatCount(followerCount)) followers")
                Text(".")
                Text("\(formatCount(videoCount)) videos")
            }
            .font(.caption2)
            .foregroundStyle(C.textMuted.opacity(0.72))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var avatar: some View {
        ZStack {
            if let avatarUrl = C.mediaURL(channel.avatarUrl) {
                AsyncImage(url: avatarUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsCircle
                }
            } else {
                initialsCircle
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay { Circle().stroke(C.bg, lineWidth: 3) }
        .background(C.bg.clipShape(Circle()))
    }

    private var initialsCircle: some View {
        Circle()
            .fill(C.elevated)
            .overlay {
                Text(channel.name.first.map(String.init)?.uppercased() ?? "?")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
    }

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Text(isFollowing ? "Following" : "Follow")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isFollowing ? C.textMuted : Color.black)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(isFollowing ? Color.white.opacity(0.1) : accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isTogglingFollow || followStatus == nil)
        .opacity(isTogglingFollow ? 0.65 : 1)
    }

    @MainActor
    private func loadFollowStatus() async {
        guard auth.isAuthenticated, followStatus == nil else { return }
        followStatus = try? await APIClient.shared.fetchChannelFollowStatus(handle: routeHandle)
    }

    @MainActor
    private func toggleFollow() async {
        guard !isTogglingFollow else { return }
        isTogglingFollow = true
        do {
            followStatus = try await APIClient.shared.toggleChannelFollow(handle: routeHandle)
        } catch {}
        isTogglingFollow = false
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
