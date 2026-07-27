import SwiftUI
import AVKit

/// Native SwiftUI curation renderer shared by browse surfaces.
/// The server owns listing order and template type; the client only maps each entity type to a native card.
struct NativeCurationListingView: View {
    let listing: AssembledListing

    private var templateType: String {
        listing.templateType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isIdentityOnly: Bool {
        !listing.items.isEmpty && listing.items.allSatisfy {
            ["channel", "person", "vibe"].contains($0.normalizedEntityType)
        }
    }

    private var isRippleOnly: Bool {
        !listing.items.isEmpty && listing.items.allSatisfy {
            $0.normalizedEntityType == "ripple"
        }
    }

    var body: some View {
        Group {
            if isIdentityOnly {
                NativeCurationIdentityTemplate(listing: listing)
            } else if isRippleOnly && templateType == "carousel" {
                NativeCurationRippleCarousel(listing: listing)
            } else {
                templateRenderer
            }
        }
        .environment(\.curationListingId, listing.listingId)
        .task(id: listing.listingId) {
            await CurationEventTracker.shared.impression(listingId: listing.listingId)
        }
    }

    @ViewBuilder
    private var templateRenderer: some View {
        switch templateType {
            case "hero":
                NativeCurationHero(listing: listing)
            case "grid":
                NativeCurationGrid(listing: listing)
            case "banner":
                NativeCurationBanner(listing: listing)
            case "spotlight":
                NativeCurationSpotlight(listing: listing)
            case "channels":
                NativeCurationChannelList(listing: listing)
            case "social_rows":
                NativeCurationSocialRows(listing: listing)
            case "carousel":
                NativeCurationCarousel(listing: listing)
            case "ripples":
                NativeCurationRippleList(listing: listing)
            case "stories":
                NativeCurationFlashesTray(listing: listing)
            case "continue_watching":
                NativeCurationContinueWatching(listing: listing)
            case "video_feed", "shorts_feed", "atmosphere_feed":
                EmptyView()
            default:
                NativeCurationCarousel(listing: listing)
        }
    }
}

private struct NativeCurationIdentityTemplate: View {
    let listing: AssembledListing

    private var templateType: String { listing.normalizedTemplateType }

    var body: some View {
        if !listing.items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                if templateType == "hero" || templateType == "banner" {
                    NativeCurationChannelFullCard(item: listing.items[0])
                        .frame(maxWidth: 680)
                        .padding(.horizontal, C.pagePad)
                } else if templateType == "carousel" || templateType == "social_rows" {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: C.gridSpacing) {
                            ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                                NativeCurationChannelFullCard(item: item)
                                    .frame(width: 290)
                            }
                        }
                        .padding(.horizontal, C.pagePad)
                        .padding(.bottom, 2)
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: C.gridSpacing)],
                        spacing: C.gridSpacing
                    ) {
                        ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                            NativeCurationChannelFullCard(item: item)
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                }
            }
        }
    }
}

private struct NativeCurationContinueWatching: View {
    let listing: AssembledListing

    @State private var items: [ProgressItem] = []
    @State private var didLoad = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: CarouselCardMetrics.spacing) {
                        ForEach(items) { item in
                            if let route = route(for: item) {
                                NavigationLink(value: route) {
                                    ContinueWatchingRailCard(
                                        title: item.episode?.title ?? item.video?.title ?? "Continue watching",
                                        subtitle: subtitle(for: item),
                                        thumbnailUrl: item.episode?.thumbnailUrl ?? item.video?.thumbnailUrl,
                                        progress: item.progress,
                                        contentType: item.video?.type ?? (item.episode == nil ? nil : "episode"),
                                        width: 160
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                }
            }
        } else if !didLoad {
            Color.clear
                .frame(height: 1)
                .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        items = (try? await APIClient.shared.fetchContinueWatching())?.items ?? []
    }

    private func route(for item: ProgressItem) -> AppRoute? {
        if let episodeId = item.episodeId ?? item.episode?.id { return .episode(episodeId) }
        if let video = item.video {
            return C.normalizedContentType(video.type) == "short"
                ? .short(video.id, showId: nil, channelId: video.channel?.id)
                : .video(video.id)
        }
        if let videoId = item.videoId { return .video(videoId) }
        return nil
    }

    private func subtitle(for item: ProgressItem) -> String? {
        if let episode = item.episode {
            let episodeLabel: String?
            if let seasonNumber = episode.season?.seasonNumber,
               let episodeNumber = episode.episodeNumber {
                episodeLabel = "S\(seasonNumber)E\(episodeNumber)"
            } else {
                episodeLabel = nil
            }
            return [episode.season?.show?.title, episodeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return item.video?.channel?.name
    }
}

/// `stories` is the frozen Backstage template key. Flashes are the existing
/// Stories product, so this renderer delegates to the established Stories
/// repository and viewer rather than inventing a separate content contract.
private struct NativeCurationFlashesTray: View {
    let listing: AssembledListing

    @EnvironmentObject private var auth: AuthManager
    @StateObject private var repository = StoriesRepository()
    @State private var viewerGroupID: String?
    @State private var activePublisher: UploadContext?
    @State private var isCreatingFlash = false

    var body: some View {
        StoryTrayView(
            repository: repository,
            activeChannel: activePublisher,
            title: listing.listingTitle ?? "",
            onAddStory: { isCreatingFlash = true }
        ) { group in
            viewerGroupID = group.id
        }
        .onAppear {
            refreshActivePublisher()
        }
        .onChange(of: auth.isAuthenticated) { _, _ in
            refreshActivePublisher()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appContextDidChange)) { _ in
            refreshActivePublisher()
        }
        .fullScreenCover(isPresented: $isCreatingFlash) {
            StoryCreatorCoordinator(preselectedPublisher: activePublisher) {
                isCreatingFlash = false
                Task { await repository.refresh(force: true) }
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { viewerGroupID != nil },
                set: { if !$0 { viewerGroupID = nil } }
            )
        ) {
            if let viewerGroupID {
                StoryViewerView(repository: repository, initialGroupId: viewerGroupID)
            }
        }
    }

    private func refreshActivePublisher() {
        guard auth.isAuthenticated,
              let context = SessionStorage.activeContext else {
            activePublisher = nil
            return
        }

        let type = context.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type == "channel" || type == "show" else {
            activePublisher = nil
            return
        }

        activePublisher = UploadContext(
            type: type,
            id: type == "channel"
                ? (context.channelId ?? context.id)
                : (context.showId ?? context.id),
            name: context.name,
            avatarUrl: context.avatarUrl ?? context.image,
            channelId: context.channelId,
            showId: context.showId,
            networkId: context.networkId,
            networkName: context.networkName
        )
    }
}

private struct CurationListingIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private extension EnvironmentValues {
    var curationListingId: String? {
        get { self[CurationListingIdKey.self] }
        set { self[CurationListingIdKey.self] = newValue }
    }
}

private struct NativeCurationRippleList: View {
    let listing: AssembledListing

    var body: some View {
        if !listing.items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                LazyVStack(spacing: C.rowSpacing) {
                    ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                        NativeCurationRippleCard(item: item)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }
}

private struct NativeCurationRippleCarousel: View {
    let listing: AssembledListing

    var body: some View {
        if !listing.items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: C.gridSpacing) {
                        ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                            NativeCurationRippleCard(item: item)
                                .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: C.gridSpacing)
                                .frame(maxWidth: 390)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, C.pagePad)
                    .padding(.bottom, 2)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}

private struct NativeCurationRippleCard: View {
    let item: ContentItem

    var body: some View {
        NavigationLink(value: item.appRoute) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NativeCurationAvatar(
                        url: item.metaString("authorImage") ?? item.metaString("clubAvatar"),
                        title: item.metaString("authorName") ?? item.metaString("clubName") ?? item.title
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.metaString("authorName") ?? item.metaString("clubName") ?? "Westreem member")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)
                        Text(item.rippleContextText)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("RIPPLE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(C.watch)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(C.watch.opacity(0.10), in: Capsule())
                }

                Text(item.displayTitle)
                    .font((item.thumbnailUrl == nil && item.coverUrl == nil) ? .body.weight(.medium) : .subheadline)
                    .foregroundStyle(C.text.opacity(0.88))
                    .lineLimit(item.thumbnailUrl == nil && item.coverUrl == nil ? 6 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding((item.thumbnailUrl == nil && item.coverUrl == nil) ? 14 : 0)
                    .background {
                        if item.thumbnailUrl == nil && item.coverUrl == nil {
                            LinearGradient(
                                colors: [C.watch.opacity(0.12), C.surface, Color.indigo.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                if item.thumbnailUrl != nil || item.coverUrl != nil {
                    NativeCurationArtwork(
                        item: item,
                        aspectRatio: 2.0,
                        cornerRadius: 12,
                        preferCover: false
                    )
                }

                HStack(spacing: 16) {
                    NativeCurationMetric(icon: "bolt.fill", count: item.metaInt("energy"), label: "Energy")
                    NativeCurationMetric(icon: "bubble.left", count: item.metaInt("comments"), label: "Comments")
                    NativeCurationMetric(icon: "wave.3.right", count: item.metaInt("echoes"), label: "Echoes")
                    if (item.metaInt("energy") ?? 0) == 0,
                       (item.metaInt("comments") ?? 0) == 0,
                       (item.metaInt("echoes") ?? 0) == 0 {
                        Text("Open Ripple")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                .frame(minHeight: 24)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surface.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(C.borderSubtle, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct NativeCurationAvatar: View {
    let url: String?
    let title: String

    var body: some View {
        CachedRemoteImage(url: C.mediaURL(url), targetSize: CGSize(width: 40, height: 40)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(C.elevated)
                .overlay {
                    Text(title.first.map(String.init)?.uppercased() ?? "?")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(C.textMuted)
                }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}

private struct NativeCurationMetric: View {
    let icon: String
    let count: Int?
    let label: String

    var body: some View {
        if let count, count > 0 {
            Label("\(count)", systemImage: icon)
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .accessibilityLabel("\(count) \(label)")
        }
    }
}

private struct NativeCurationHeader: View {
    let listing: AssembledListing
    let showSeeAll: Bool

    private var accentColor: Color { listing.accentColor.map(Color.init(hex:)) ?? C.watch }
    private var seeAllRoute: AppRoute? { listing.seeAllUrl.flatMap { AppRoute.route(link: $0) } }

    var body: some View {
        let title = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let badge = listing.badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == false || badge?.isEmpty == false {
            HStack(alignment: .center, spacing: 8) {
                if let badge, !badge.isEmpty {
                    Text(badge.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .stroke(accentColor.opacity(0.30), lineWidth: 1)
                        }
                }
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                }
                if let sponsor = listing.sponsoredBy, !sponsor.isEmpty {
                    Text("· Sponsored")
                        .font(.system(size: 10))
                        .foregroundStyle(C.textTertiary)
                }
                Spacer(minLength: 8)
                if showSeeAll, let seeAllRoute {
                    NavigationLink(value: seeAllRoute) {
                        Text("See all →")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, C.pagePad)
        }
    }
}

private extension AssembledListing {
    var hasVisibleCurationHeader: Bool {
        let title = listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let badge = badge?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false || badge?.isEmpty == false
    }

    var curationHeaderSpacing: CGFloat {
        hasVisibleCurationHeader ? C.rowSpacing : 0
    }
}

private struct NativeCurationCarousel: View {
    let listing: AssembledListing

    var body: some View {
        if !listing.items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: C.rowSpacing) {
                        ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                            NativeCurationEntityCard(item: item, mode: .carousel)
                                .frame(width: NativeCurationEntityCard.width(for: item, mode: .carousel))
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct NativeCurationDisplayItem: Identifiable {
    let id: String
    let item: ContentItem
    let searchText: String

    init(listingID: String, offset: Int, item: ContentItem) {
        self.id = "\(listingID)-\(offset)-\(item.id)"
        self.item = item
        self.searchText = [item.displayTitle, item.curationSubtitle, item.entityType]
            .joined(separator: " ")
            .lowercased()
    }
}

private struct NativeCurationGrid: View {
    let listing: AssembledListing
    let prefersChannelTreatment: Bool
    private let displayItems: [NativeCurationDisplayItem]

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filterQuery = ""
    @State private var appliedFilterQuery = ""
    @State private var filterTask: Task<Void, Never>?

    init(listing: AssembledListing, prefersChannelTreatment: Bool = false) {
        self.listing = listing
        self.prefersChannelTreatment = prefersChannelTreatment
        self.displayItems = listing.items.enumerated().map { offset, item in
            NativeCurationDisplayItem(listingID: listing.id, offset: offset, item: item)
        }
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: C.rowSpacing, alignment: .top), count: count)
    }

    private var filteredItems: [NativeCurationDisplayItem] {
        let query = appliedFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return displayItems }
        return displayItems.filter { $0.searchText.contains(query) }
    }

    private var shouldShowFilter: Bool {
        displayItems.count > 8
    }

    var body: some View {
        if !displayItems.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                if shouldShowFilter {
                    NativeCurationInlineSearchField(query: $filterQuery, placeholder: searchPlaceholder)
                        .padding(.horizontal, C.pagePad)
                }
                LazyVGrid(columns: columns, spacing: C.gridSpacing) {
                    ForEach(filteredItems) { displayItem in
                        NativeCurationEntityCard(
                            item: displayItem.item,
                            mode: prefersChannelTreatment ? .channelGrid : .grid
                        )
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
            .onChange(of: filterQuery) { _, newValue in
                scheduleFilterApply(newValue)
            }
            .onDisappear {
                filterTask?.cancel()
            }
        }
    }

    private var searchPlaceholder: String {
        let title = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return "Search items..." }
        return "Search \(title.lowercased())..."
    }

    private func scheduleFilterApply(_ value: String) {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            appliedFilterQuery = value
        }
    }
}

private struct NativeCurationChannelList: View {
    let listing: AssembledListing
    private let displayItems: [NativeCurationDisplayItem]

    @State private var filterQuery = ""
    @State private var appliedFilterQuery = ""
    @State private var filterTask: Task<Void, Never>?

    init(listing: AssembledListing) {
        self.listing = listing
        self.displayItems = listing.items.enumerated().map { offset, item in
            NativeCurationDisplayItem(listingID: listing.id, offset: offset, item: item)
        }
    }

    private var channelItems: [NativeCurationDisplayItem] {
        let query = appliedFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return displayItems }
        return displayItems.filter { $0.searchText.contains(query) }
    }

    private var shouldShowFilter: Bool { displayItems.count > 8 }

    var body: some View {
        if !displayItems.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                if shouldShowFilter {
                    NativeCurationInlineSearchField(query: $filterQuery, placeholder: searchPlaceholder)
                        .padding(.horizontal, C.pagePad)
                }
                LazyVStack(spacing: C.gridSpacing) {
                    ForEach(channelItems) { displayItem in
                        let item = displayItem.item
                        if item.normalizedEntityType == "channel" {
                            NativeCurationChannelFullCard(item: item)
                        } else {
                            NativeCurationEntityCard(item: item, mode: .grid)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(C.surface)
                                .clipShape(RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous)
                                        .stroke(C.borderSubtle, lineWidth: 1)
                                }
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
            .onChange(of: filterQuery) { _, newValue in
                scheduleFilterApply(newValue)
            }
            .onDisappear {
                filterTask?.cancel()
            }
        }
    }

    private var searchPlaceholder: String {
        let title = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return "Search channels..." }
        return "Search \(title.lowercased())..."
    }

    private func scheduleFilterApply(_ value: String) {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            appliedFilterQuery = value
        }
    }
}

private struct NativeCurationSocialRows: View {
    let listing: AssembledListing

    var body: some View {
        if !listing.items.isEmpty {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                LazyVStack(spacing: 0) {
                    ForEach(Array(listing.items.enumerated()), id: \.offset) { index, item in
                        NavigationLink(value: item.appRoute) {
                            HStack(spacing: 12) {
                                NativeCurationAvatar(
                                    url: item.thumbnailUrl,
                                    title: item.displayTitle
                                )
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(C.text)
                                        .lineLimit(1)
                                    if !item.curationSubtitle.isEmpty {
                                        Text(item.curationSubtitle)
                                            .font(.caption)
                                            .foregroundStyle(C.textMuted)
                                            .lineLimit(1)
                                    }
                                    if let description = item.metaString("description"), !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(C.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text("View")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(C.textMuted)
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(C.elevated, in: Capsule())
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(C.borderSubtle)
                                        .frame(height: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(C.surface.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(C.borderSubtle, lineWidth: 1)
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }
}

private struct NativeCurationChannelFullCard: View {
    let item: ContentItem
    let channel: ChannelBrowseCard

    init(item: ContentItem) {
        self.item = item
        self.channel = item.asChannelBrowseCard
    }

    private var followerCount: Int { channel._count?.followers ?? 0 }
    private var videoCount: Int { channel._count?.videos ?? item.metaInt("videos") ?? 0 }
    private var primaryCount: String {
        switch item.normalizedEntityType {
        case "vibe":
            return "\(formatCount(item.metaInt("members") ?? 0)) members"
        default:
            return "\(formatCount(followerCount)) followers"
        }
    }
    private var secondaryCount: String {
        switch item.normalizedEntityType {
        case "vibe":
            return "\(formatCount(item.metaInt("ripples") ?? 0)) Ripples"
        case "person":
            return "Atmo"
        default:
            return "\(formatCount(videoCount)) videos"
        }
    }

    var body: some View {
        NavigationLink(value: item.appRoute) {
            VStack(spacing: 0) {
                banner
                bodyContent
            }
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: C.cardRadius, style: .continuous)
                    .stroke(C.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var banner: some View {
        ZStack {
            if let bannerUrl = C.mediaURL(channel.bannerUrl) {
                CachedRemoteImage(url: bannerUrl, targetSize: CGSize(width: UIScreen.main.bounds.width - C.pagePad * 2, height: 96)) { image in
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
            colors: [C.watch.opacity(0.18), C.watch.opacity(0.04)],
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
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(C.textMuted.opacity(0.65))
            }

            HStack(spacing: 5) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                if channel.verified {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(C.watch)
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
                Text(primaryCount)
                Text(".")
                Text(secondaryCount)
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
                CachedRemoteImage(url: avatarUrl, targetSize: CGSize(width: 58, height: 58)) { image in
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
                Text(item.displayTitle.first.map(String.init)?.uppercased() ?? "?")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct NativeCurationHero: View {
    let listing: AssembledListing

    @State private var trailerPlayer: AVQueuePlayer?
    @State private var trailerLooper: AVPlayerLooper?
    @State private var trailerMuted = true
    @State private var trailerVisible = false
    @State private var trailerStartTask: Task<Void, Never>?
    @State private var activeIndex = 0

    private var item: ContentItem? {
        guard listing.items.indices.contains(activeIndex) else { return listing.items.first }
        return listing.items[activeIndex]
    }
    private var accentColor: Color { listing.accentColor.map(Color.init(hex:)) ?? C.watch }

    var body: some View {
        if let item {
            ZStack(alignment: .topTrailing) {
                NavigationLink(value: item.appRoute) {
                    heroCard(for: item)
                }
                .buttonStyle(.plain)

                if trailerPlayer != nil, trailerVisible {
                    Button { toggleTrailerMute() } label: {
                        Image(systemName: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.48), in: Circle())
                            .overlay { Circle().stroke(Color.white.opacity(0.18), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.trailing, 14)
                        .accessibilityLabel(trailerMuted ? "Unmute trailer" : "Mute trailer")
                }

                if listing.items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(listing.items.indices, id: \.self) { index in
                            Button {
                                selectHero(index)
                            } label: {
                                Capsule()
                                    .fill(.white.opacity(index == activeIndex ? 0.95 : 0.38))
                                    .frame(width: index == activeIndex ? 20 : 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show feature \(index + 1)")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
                }
            }
            .onAppear { startTrailerIfAvailable(for: item) }
            .onDisappear { stopTrailer() }
            .onChange(of: item.entityId) { _, _ in
                stopTrailer()
                startTrailerIfAvailable(for: item)
            }
        }
    }

    @MainActor
    private func selectHero(_ index: Int) {
        guard listing.items.indices.contains(index), index != activeIndex else { return }
        stopTrailer()
        activeIndex = index
    }

    private func heroCard(for item: ContentItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                heroMedia(for: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: C.heroHeight)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.04), .black.opacity(0.42), .black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(trailerVisible ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: trailerVisible)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text((listing.badge ?? item.entityTypeDisplayName).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accentColor)
                    .tracking(2)
                Text(item.displayTitle)
                    .font(.system(size: 30, weight: .bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if !item.heroDescription.isEmpty {
                    Text(item.heroDescription)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    Image(systemName: item.primaryActionIconName)
                        .font(.system(size: 13, weight: .bold))
                    Text(item.primaryActionTitle)
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(C.bg)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(accentColor)
                .clipShape(Capsule())
            }
            .padding(.horizontal, C.pagePad)
            .padding(.top, 12)
            .padding(.bottom, C.pagePad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func heroMedia(for item: ContentItem) -> some View {
        ZStack {
            heroImage(for: item)
                .overlay { Color.black.opacity(trailerVisible ? 0 : 0.12) }

            if let trailerPlayer {
                NativeCurationTrailerSurface(player: trailerPlayer)
                    .background(Color.black)
                    .opacity(trailerVisible ? 0.72 : 0)
                    .animation(.easeInOut(duration: 0.55), value: trailerVisible)
            }
        }
    }

    private func heroImage(for item: ContentItem) -> some View {
        GeometryReader { proxy in
            CachedRemoteImage(
                url: C.mediaURL(item.coverUrl ?? item.thumbnailUrl),
                targetSize: CGSize(width: proxy.size.width, height: proxy.size.height)
            ) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            } placeholder: {
                LinearGradient(
                    colors: [C.watch.opacity(0.18), C.bg],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .clipped()
        }
    }

    @MainActor
    private func startTrailerIfAvailable(for item: ContentItem) {
        guard trailerPlayer == nil else { return }
        guard let trailerURL = item.trailerURL else {
            guard listing.items.count > 1 else { return }
            trailerStartTask?.cancel()
            trailerStartTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                selectHero((activeIndex + 1) % listing.items.count)
            }
            return
        }
        let playerItem = AVPlayerItem(url: trailerURL)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 1
        trailerMuted = true
        trailerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
        trailerPlayer = player
        trailerStartTask?.cancel()
        trailerStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, trailerPlayer === player else { return }
            player.play()
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, trailerPlayer === player else { return }
            trailerVisible = true
        }
    }

    @MainActor
    private func toggleTrailerMute() {
        trailerMuted.toggle()
        trailerPlayer?.isMuted = trailerMuted
    }

    @MainActor
    private func stopTrailer() {
        trailerStartTask?.cancel()
        trailerStartTask = nil
        trailerVisible = false
        trailerPlayer?.pause()
        trailerLooper = nil
        trailerPlayer = nil
    }
}

private struct NativeCurationTrailerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        var player: AVPlayer? {
            get { playerLayer?.player }
            set {
                playerLayer?.player = newValue
                playerLayer?.videoGravity = .resizeAspectFill
            }
        }
    }
}

private struct NativeCurationBanner: View {
    let listing: AssembledListing

    private var item: ContentItem? { listing.items.first }
    private var accentColor: Color { listing.accentColor.map(Color.init(hex:)) ?? C.watch }
    private var title: String? {
        let listingTitle = listing.listingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return listingTitle?.isEmpty == false ? listingTitle : item?.displayTitle
    }

    var body: some View {
        if let item {
            NavigationLink(value: listing.seeAllUrl.flatMap { AppRoute.route(link: $0) } ?? item.appRoute) {
                ZStack {
                    NativeCurationArtwork(item: item, aspectRatio: 16.0 / 6.0, cornerRadius: 12, preferCover: false)
                    LinearGradient(
                        colors: [.black.opacity(0.72), .black.opacity(0.20)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let badge = listing.badge, !badge.isEmpty {
                                Text(badge.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(accentColor)
                            }
                            if let title, !title.isEmpty {
                                Text(title)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            if listing.listingTitle != nil {
                                Text(item.displayTitle)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Label(item.primaryActionTitle, systemImage: item.primaryActionIconName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(accentColor, in: Capsule())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 18)

                    if listing.sponsoredBy?.isEmpty == false {
                        Text("Sponsored")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(8)
                        }
                }
                .padding(.horizontal, C.pagePad)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NativeCurationSpotlight: View {
    let listing: AssembledListing

    private var accentColor: Color { listing.accentColor.map(Color.init(hex:)) ?? C.watch }

    var body: some View {
        if let featured = listing.items.first {
            VStack(alignment: .leading, spacing: listing.curationHeaderSpacing) {
                NativeCurationHeader(listing: listing, showSeeAll: true)
                VStack(spacing: C.gridSpacing) {
                    NavigationLink(value: featured.appRoute) {
                        ZStack(alignment: .bottomLeading) {
                            NativeCurationArtwork(
                                item: featured,
                                aspectRatio: 16.0 / 9.0,
                                cornerRadius: 12,
                                preferCover: false
                            )
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.72)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                if let badge = listing.badge, !badge.isEmpty {
                                    Text(badge.uppercased())
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(1.2)
                                        .foregroundStyle(accentColor)
                                }
                                Text(featured.displayTitle)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                if let genre = featured.metaString("genre"), !genre.isEmpty {
                                    Text(genre)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            .padding(14)
                        }
                    }
                    .buttonStyle(.plain)

                    let supporting = Array(listing.items.dropFirst().prefix(3))
                    if !supporting.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: C.gridSpacing) {
                                ForEach(Array(supporting.enumerated()), id: \.offset) { _, item in
                                    NavigationLink(value: item.appRoute) {
                                        HStack(alignment: .top, spacing: 10) {
                                            NativeCurationArtwork(
                                                item: item,
                                                aspectRatio: item.cardAspectRatio,
                                                cornerRadius: 8,
                                                preferCover: false
                                            )
                                            .frame(width: 92)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.displayTitle)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(C.text)
                                                    .lineLimit(2)
                                                if !item.curationSubtitle.isEmpty {
                                                    Text(item.curationSubtitle)
                                                        .font(.caption2)
                                                        .foregroundStyle(C.textTertiary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            .padding(.top, 2)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(width: 230, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }
}

private struct NativeCurationEntityCard: View {
    enum Mode {
        case carousel
        case grid
        case channelGrid
    }

    let item: ContentItem
    let mode: Mode
    @Environment(\.curationListingId) private var curationListingId

    static func width(for item: ContentItem, mode: Mode) -> CGFloat {
        switch item.normalizedEntityType {
        case "video", "episode": return 160
        case "show", "season", "short": return 140
        case "channel", "person", "vibe", "topic": return 160
        case "ripple": return 220
        default: return 160
        }
    }

    private var aspectRatio: CGFloat {
        switch mode {
        case .channelGrid where item.normalizedEntityType == "channel": return 1.0
        default: return item.cardAspectRatio
        }
    }

    var body: some View {
        NavigationLink(value: item.appRoute) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    NativeCurationArtwork(item: item, aspectRatio: aspectRatio, cornerRadius: C.cardRadius, preferCover: mode == .channelGrid)
                        .overlay(alignment: .topLeading) {
                            if let typeLabel = item.curationTypePill {
                                Text(typeLabel.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.60))
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .padding(6)
                            }
                        }
                    if let duration = item.durationLabel {
                        Text(duration)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.78))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(6)
                    }
                    if item.isRentable {
                        Text("RENT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color(hex: "#F59E0B"))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }

                HStack(spacing: 5) {
                    Text(item.displayTitle)
                        .font(.system(size: 12, weight: mode == .grid ? .semibold : .medium))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                    if item.isVerifiedChannel {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.watch)
                    }
                }

                if !item.curationSubtitle.isEmpty {
                    Text(item.curationSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(C.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            guard let curationListingId else { return }
            Task {
                await CurationEventTracker.shared.click(
                    listingId: curationListingId,
                    contentId: item.entityId
                )
            }
        })
    }
}

private struct NativeCurationArtwork: View {
    let item: ContentItem
    let aspectRatio: CGFloat
    let cornerRadius: CGFloat
    let preferCover: Bool

    private var url: URL? {
        C.mediaURL(preferCover ? (item.coverUrl ?? item.thumbnailUrl) : (item.thumbnailUrl ?? item.coverUrl))
    }

    var body: some View {
        ZStack {
            CachedRemoteImage(url: url, targetSize: targetSize) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                fallback
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .background(C.elevated)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(C.borderSubtle, lineWidth: 1)
        }
    }

    private var targetSize: CGSize {
        let width = min(UIScreen.main.bounds.width - C.pagePad * 2, preferCover ? 520 : 240)
        return CGSize(width: width, height: width / aspectRatio)
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [C.elevated, C.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.fallbackIconName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(C.textTertiary)
        }
    }
}

private struct NativeCurationInlineSearchField: View {
    @Binding var query: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(C.textMuted)
            TextField(placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(C.text)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(C.elevated)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(C.borderSubtle, lineWidth: 1)
        }
    }
}

private extension ContentItem {
    var displayTitle: String {
        curationDisplayTitle
    }

    var normalizedEntityType: String {
        entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var entityTypeDisplayName: String {
        switch normalizedEntityType {
        case "show": return metaString("showType")?.capitalized ?? "Series"
        case "video": return "Video"
        case "short": return "Short"
        case "episode": return "Episode"
        case "channel": return "Channel"
        case "ripple": return "Ripple"
        case "person": return "Person"
        case "vibe": return "Vibe"
        case "topic": return "Topic"
        case "season": return "Season"
        default: return normalizedEntityType.capitalized.isEmpty ? "Featured" : normalizedEntityType.capitalized
        }
    }

    var curationTypePill: String? {
        switch normalizedEntityType {
        case "show": return nil
        case "short": return "Short"
        case "video": return "Video"
        case "episode": return "Ep"
        case "season": return "Season"
        case "channel": return "Channel"
        case "ripple": return "Ripple"
        case "person": return "Person"
        case "vibe": return "Vibe"
        case "topic": return "Topic"
        default: return nil
        }
    }

    var heroDescription: String {
        if let description = metaString("description")?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return curationSubtitle
    }

    var curationSubtitle: String {
        switch normalizedEntityType {
        case "show":
            return [metaString("productionYear"), seasonText, metaString("genre")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "video", "short":
            return [metaString("channelName"), viewsText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "episode":
            let episode = episodeNumberText
            return [episode, metaString("showTitle")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "channel":
            return [channelHandleText, followersText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "ripple":
            return rippleContextText
        case "person":
            return [channelHandleText, followersText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "vibe":
            return [membersText, ripplesText]
                .compactMap { $0 }
                .joined(separator: " · ")
        case "topic":
            return metaString("description") ?? metaString("domain") ?? ""
        case "season":
            return [metaString("showTitle"), episodeCountText]
                .compactMap { $0 }
                .joined(separator: " · ")
        default:
            return [metaString("channelName"), viewsText, metaString("genre")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    var cardAspectRatio: CGFloat {
        switch normalizedEntityType {
        case "show": return 2.0 / 3.0
        case "short": return 9.0 / 16.0
        case "channel": return 1.0
        case "person", "vibe", "topic": return 1.0
        case "season": return 2.0 / 3.0
        case "ripple": return 16.0 / 9.0
        case "video", "episode": return 16.0 / 9.0
        default: return C.mediaAspectRatio(forContentType: metaString("type") ?? entityType)
        }
    }

    var spotlightAspectRatio: CGFloat {
        normalizedEntityType == "short" ? 9.0 / 16.0 : 16.0 / 9.0
    }

    var durationLabel: String? {
        guard let seconds = metaDouble("duration") ?? metaInt("duration").map(Double.init), seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    var primaryActionTitle: String {
        switch normalizedEntityType {
        case "channel": return "Open Channel"
        case "person": return "Open Atmo"
        case "vibe": return "Open Vibe"
        case "ripple": return "Open Ripple"
        case "topic": return "Explore Topic"
        default: return "Watch Now"
        }
    }

    var primaryActionIconName: String {
        ["channel", "person", "vibe", "ripple", "topic"].contains(normalizedEntityType) ? "arrow.right" : "play.fill"
    }

    var fallbackIconName: String {
        switch normalizedEntityType {
        case "show": return "tv"
        case "video": return "play.rectangle"
        case "short": return "bolt.fill"
        case "episode": return "film"
        case "channel": return "person.crop.square"
        case "ripple": return "wave.3.right"
        case "person": return "person.crop.circle"
        case "vibe": return "person.3"
        case "topic": return "number"
        case "season": return "rectangle.stack"
        default: return "rectangle.stack"
        }
    }

    var isVerifiedChannel: Bool {
        normalizedEntityType == "channel" && (metaBool("verified") ?? false)
    }

    var isRentable: Bool {
        metaString("entitlementType")?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PPV"
    }

    private var seasonText: String? {
        guard let seasons = metaInt("seasons"), seasons > 0 else { return nil }
        return seasons == 1 ? "1 season" : "\(seasons) seasons"
    }

    private var viewsText: String? {
        guard let views = metaInt("views") else { return nil }
        return "\(Self.abbreviatedCount(views)) views"
    }

    private var followersText: String? {
        guard let followers = metaInt("followers") else { return nil }
        return "\(Self.abbreviatedCount(followers)) followers"
    }

    var rippleContextText: String {
        let handle = metaString("authorHandle").map { $0.hasPrefix("@") ? $0 : "@\($0)" }
        let vibe = metaString("clubName")
        return [handle, vibe].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var membersText: String? {
        guard let members = metaInt("members"), members > 0 else { return nil }
        return "\(Self.abbreviatedCount(members)) members"
    }

    private var ripplesText: String? {
        guard let ripples = metaInt("ripples"), ripples > 0 else { return nil }
        return "\(Self.abbreviatedCount(ripples)) ripples"
    }

    private var episodeCountText: String? {
        guard let episodes = metaInt("episodes"), episodes > 0 else { return nil }
        return episodes == 1 ? "1 episode" : "\(episodes) episodes"
    }

    private var channelHandleText: String? {
        let handle = metaString("handle") ?? metaString("channelHandle")
        guard let handle, !handle.isEmpty else { return nil }
        return handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    private var episodeNumberText: String? {
        let season = metaInt("seasonNumber")
        let episode = metaInt("episodeNumber")
        if let season, let episode { return "S\(season) E\(episode)" }
        if let episode { return "Episode \(episode)" }
        return nil
    }

    private static func abbreviatedCount(_ value: Int) -> String {
        let number = Double(value)
        if value >= 1_000_000 {
            return String(format: number >= 10_000_000 ? "%.0fM" : "%.1fM", number / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: number >= 10_000 ? "%.0fK" : "%.1fK", number / 1_000)
        }
        return "\(value)"
    }
}
