import SwiftUI
import AVKit

// NON_SERIES_TYPES — matches web src/app/shows/[id]/ShowClient.tsx
private let NON_SERIES_TYPES: Set<String> = ["movie", "film", "special", "event", "concert", "short"]

// MARK: - ShowView

struct ShowView: View {

    let showId: String
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    // API data
    @State private var showResp:    ShowPageResponse?
    @State private var followStatus: FollowStatus?
    @State private var clips:        [ShowClip]?
    @State private var playlists:    [ChannelPlaylist]?
    @State private var isLoading:    Bool = true
    @State private var loadError:    String?

    // UI state
    @State private var activeTab:      STab = .episodes
    @State private var synopsisExpanded: Bool = false
    @State private var followLoading:  Bool = false
    @State private var notifyLoading:  Bool = false
    @State private var checkoutProduct: ShowCheckoutProduct?
    @State private var checkoutMode: ShowCheckoutMode = .svod
    @State private var checkoutMessage: String?
    @State private var showSaveSheet: Bool = false

    enum STab: String, CaseIterable, Identifiable {
        case episodes, videos, shorts, allVideos, playlists, related, info
        var id: String { rawValue }
        var label: String {
            switch self {
            case .episodes:  return "Episodes"
            case .videos:    return "Videos"
            case .shorts:    return "Shorts"
            case .allVideos: return "All Videos"
            case .playlists: return "Playlists"
            case .related:   return "Related"
            case .info:      return "About"
            }
        }
    }

    // MARK: - Derived

    private var show: ShowData? { showResp?.show }
    private var relatedShows: [RelatedShow] { showResp?.relatedShows ?? [] }
    private var isNonSerialized: Bool { NON_SERIES_TYPES.contains(show?.showType ?? "") }
    private var allEpisodes: [(season: ShowSeasonData, ep: ShowEpisodeItem)] {
        (show?.seasons ?? []).flatMap { s in s.episodes.map { (s, $0) } }
    }
    private var videosList: [ShowClip] { (clips ?? []).filter { !isShortClip($0) } }
    private var shortsList: [ShowClip] { (clips ?? []).filter { isShortClip($0) } }
    private var firstPlayableEpisodeId: String? {
        allEpisodes.first { $0.ep.isPlayable }?.ep.id
    }
    private var isFollowing: Bool { followStatus?.subscribed ?? (show?.isFollowing ?? false) }
    private var notifyOn:    Bool { followStatus?.notifyOnPublish ?? true }
    private var followerCount: Int { followStatus?.count ?? (show?.followerCount ?? 0) }

    private var availableTabs: [STab] {
        guard show != nil else { return [] }
        var tabs: [STab] = []
        if !isNonSerialized && !allEpisodes.isEmpty    { tabs.append(.episodes) }
        if !videosList.isEmpty                         { tabs.append(.videos) }
        if !shortsList.isEmpty                         { tabs.append(.shorts) }
        if !videosList.isEmpty && !shortsList.isEmpty  { tabs.append(.allVideos) }
        if playlists?.isEmpty == false                 { tabs.append(.playlists) }
        if !relatedShows.isEmpty                       { tabs.append(.related) }
        tabs.append(.info)
        return tabs
    }

    private func isShortClip(_ clip: ShowClip) -> Bool {
        clip.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "short"
    }

    private func seasonAnchorId(_ seasonId: String) -> String {
        "season-\(seasonId)"
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(C.watch)
            } else if let sh = show {
                showContent(sh)
            } else {
                loadFailureView
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $checkoutProduct) { product in
            ShowCheckoutSheet(
                product: product,
                mode: checkoutMode,
                onCancel: { checkoutProduct = nil },
                onConfirm: { await runCheckout(product: product, mode: checkoutMode) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveToCollectionSheet(showId: showId)
        }
        .alert("Checkout", isPresented: Binding(
            get: { checkoutMessage != nil },
            set: { if !$0 { checkoutMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(checkoutMessage ?? "")
        }
    }

    // MARK: - Main scroll

    private func showContent(_ sh: ShowData) -> some View {
        GeometryReader { proxy in
            let pageWidth = proxy.size.width
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .topLeading) {
                ScrollViewReader { pageScrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            heroSection(sh, width: pageWidth)
                            showDescriptionSection(sh)
                                .frame(width: pageWidth)
                            tabBarSection(sh)
                                .frame(width: pageWidth)
                            tabContentSection(sh, width: pageWidth, pageScrollProxy: pageScrollProxy)
                                .padding(.top, 12)
                                .padding(.bottom, 40)
                        }
                        .frame(width: pageWidth, alignment: .topLeading)
                    }
                    .scrollClipDisabled(false)
                    .ignoresSafeArea(edges: .top)
                }

                heroBackButton()
                    .padding(.leading, 16)
                    .padding(.top, max(12, topInset - 6))
            }
        }
    }

    // MARK: - Hero

    private func heroBackButton() -> some View {
        Button {
            dismiss()
        } label: {
            MediaverseIcon(name: "chevron-left", fallbackSystemName: "chevron.left")
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.30))
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    private func heroSection(_ sh: ShowData, width: CGFloat) -> some View {
        let heroHeight: CGFloat = isNonSerialized ? 400 : 320

        return ZStack(alignment: .bottomLeading) {
            // Background: banner or gradient
            heroBackground(sh, width: width, height: heroHeight)

            // Content overlay
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                heroMeta(sh)
                    .padding(.horizontal, C.pagePad)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width)
            .frame(height: heroHeight)
        }
        .frame(width: width)
        .frame(height: heroHeight)
        .clipped()
    }

    @ViewBuilder
    private func heroBackground(_ sh: ShowData, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Banner image
            if let url = C.mediaURL(sh.bannerUrl ?? sh.coverUrl) {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                    placeholder: { C.surface }
                    .frame(width: width)
                    .frame(height: height)
                    .clipped()
            } else {
                LinearGradient(colors: [C.surface, C.bg], startPoint: .top, endPoint: .bottom)
                    .frame(width: width)
                    .frame(height: height)
            }

            // Gradient overlays (same as web double-gradient)
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.6), .black.opacity(0.10)],
                startPoint: .bottom, endPoint: .init(x: 0.5, y: 0.45)
            )
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)
            )
        }
        .frame(width: width)
        .frame(height: height)
        .clipped()
    }

    @ViewBuilder
    private func heroMeta(_ sh: ShowData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Show title
            Text(sh.title)
                .font(isNonSerialized
                      ? .system(size: 30, weight: .black)
                      : .system(size: 26, weight: .black))
                .foregroundStyle(C.text)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata pills row
            metadataRow(sh)

            // CTA buttons
            heroCTAs(sh)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ sh: ShowData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let cr = sh.contentRating, !cr.isEmpty {
                    metaBadge(cr, style: .bordered)
                }
                if let genre = sh.genre, !genre.isEmpty {
                    metaBadge(genre.capitalized, style: .pill)
                }
                if !isNonSerialized {
                    let nS = sh.seasons.count
                    let nE = allEpisodes.count
                    if nS > 0 {
                        Text("\(nS) Season\(nS == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                    }
                    if nE > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(C.textMuted.opacity(0.4))
                        Text("\(nE) Episode\(nE == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                    }
                } else {
                    // Non-serialized: year, runtime, language
                    if let airDate = sh.seasons.first?.airDate ?? sh.seasons.first?.episodes.first?.airDate {
                        let year = String(airDate.prefix(4))
                        if !year.isEmpty {
                            Text(year)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(C.textMuted)
                        }
                    }
                    if sh.language != "en" && !sh.language.isEmpty {
                        metaBadge(sh.language.uppercased(), style: .bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metaBadge(_ text: String, style: BadgeStyle) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(style == .bordered ? C.textMuted : C.watch)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(style == .bordered ? .white.opacity(0.08) : C.watch.opacity(0.12))
            .overlay {
                if style == .bordered {
                    RoundedRectangle(cornerRadius: 4).stroke(C.border.opacity(0.6), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: style == .bordered ? 4 : 20))
    }

    private enum BadgeStyle { case bordered, pill }

    @ViewBuilder
    private func showDescriptionSection(_ sh: ShowData) -> some View {
        if let desc = sh.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(desc)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(C.text.opacity(0.82))
                    .lineLimit(synopsisExpanded ? nil : 3)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if desc.count > 160 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            synopsisExpanded.toggle()
                        }
                    } label: {
                        Text(synopsisExpanded ? "Show less" : "More")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.watch)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.bg)
        }
    }

    private func heroCTAs(_ sh: ShowData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Primary watch / access button
                primaryCTA(sh)
                    .fixedSize(horizontal: true, vertical: false)

                // Follow button
                Button {
                    Task { await toggleFollow(sh) }
                } label: {
                    Text(isFollowing ? "✓ Following" : "Follow")
                        .font(.subheadline.bold())
                        .foregroundStyle(isFollowing ? .white : .black)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(isFollowing ? .white.opacity(0.15) : .white)
                        .clipShape(Capsule())
                        .overlay {
                            if isFollowing { Capsule().stroke(C.border, lineWidth: 1) }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                }
                .disabled(followLoading)

                // Bell (only when following)
                if isFollowing {
                    Button {
                        Task { await toggleNotify(sh) }
                    } label: {
                        Image(systemName: notifyOn ? "bell.fill" : "bell.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(notifyOn ? .white : C.textMuted)
                            .frame(width: 40, height: 40)
                            .background(notifyOn ? .white.opacity(0.20) : C.surface)
                            .clipShape(Circle())
                            .overlay { Circle().stroke(notifyOn ? .white.opacity(0.30) : C.border, lineWidth: 1) }
                    }
                    .disabled(notifyLoading)
                }

                // Share
                Button {
                    guard let url = URL(string: "\(C.baseURL)/shows/\(sh.id)") else { return }
                    UIActivityViewController(activityItems: [url], applicationActivities: nil).presentFromRoot()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(C.text)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12))
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }
                }

                // Save show
                Button {
                    showSaveSheet = true
                } label: {
                    Image(systemName: "bookmark")
                        .font(.system(size: 14))
                        .foregroundStyle(C.text)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12))
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func primaryCTA(_ sh: ShowData) -> some View {
        let entType = sh.entitlementType ?? "AVOD"
        let hasAccess = entType == "AVOD"
            || sh.userSubscribed
            || !sh.userSeasonRentals.isEmpty

        if hasAccess {
            // Watch Now CTA
            if let firstEpId = firstPlayableEpisodeId {
                NavigationLink(value: AppRoute.episode(firstEpId)) {
                    watchNowLabel
                }
            } else if let firstClip = videosList.first {
                NavigationLink(value: AppRoute.video(firstClip.id)) {
                    watchNowLabel
                }
            }
        } else if entType == "SVOD", let prod = sh.svodProducts.first {
            Button {
                presentCheckout(product: prod, mode: .svod, season: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Subscribe")
                    if let price = prod.price {
                        Text("· \(fmtPrice(price, currency: prod.currency ?? "USD"))")
                            .font(.caption.weight(.medium))
                            .opacity(0.75)
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(C.watch)
                .clipShape(Capsule())
            }
        } else if entType == "PPV" || entType == "TRANSACTIONAL",
                  let prod = sh.ppvProducts.first {
            Button {
                presentCheckout(product: prod, mode: .ppv, season: sh.seasons.first)
            } label: {
                HStack(spacing: 6) {
                    Text("🎬")
                    Text("Rent")
                    if let price = prod.price {
                        Text("· \(fmtPrice(price, currency: prod.currency ?? "USD"))")
                            .font(.caption.weight(.medium))
                            .opacity(0.75)
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(C.watch)
                .clipShape(Capsule())
            }
        } else if sh.userSubscribed {
            // Subscribed, content coming soon
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text("Subscribed")
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white.opacity(0.50))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.white.opacity(0.10))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(C.border, lineWidth: 1) }
        }
    }

    private var watchNowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
            Text(isNonSerialized ? "Watch Now" : "Watch E1")
        }
        .font(.subheadline.bold())
        .foregroundStyle(.black)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(C.watch)
        .clipShape(Capsule())
    }

    // MARK: - Tab bar

    private func tabBarSection(_ sh: ShowData) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(availableTabs) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                activeTab = tab
                                reader.scrollTo(tab.id, anchor: .center)
                            }
                        } label: {
                            Text(tab.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(activeTab == tab ? C.text : C.textMuted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if activeTab == tab {
                                        Rectangle()
                                            .fill(C.watch)
                                            .frame(height: 2)
                                            .offset(y: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
            .frame(height: 46)
        }
        .frame(height: 46)
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Divider().background(C.border)
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContentSection(_ sh: ShowData, width: CGFloat, pageScrollProxy: ScrollViewProxy) -> some View {
        switch activeTab {
        case .episodes:
            episodesTab(sh, pageScrollProxy: pageScrollProxy)
                .frame(width: width - (C.pagePad * 2), alignment: .leading)
                .padding(.horizontal, C.pagePad)
                .frame(width: width, alignment: .leading)

        case .videos:
            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(videosList) { v in
                    NavigationLink(value: AppRoute.video(v.id)) {
                        ShowClipCard(clip: v, style: .video)
                    }
                }
            }
            .frame(width: width - (C.pagePad * 2), alignment: .leading)
            .padding(.horizontal, C.pagePad)
            .frame(width: width, alignment: .leading)

        case .shorts:
            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(shortsList) { v in
                    NavigationLink(value: AppRoute.short(v.id, showId: sh.id, channelId: nil)) {
                        ShowClipCard(clip: v, style: .short)
                    }
                }
            }
            .frame(width: width - (C.pagePad * 2), alignment: .leading)
            .padding(.horizontal, C.pagePad)
            .frame(width: width, alignment: .leading)

        case .allVideos:
            allVideosTab(sh)
                .frame(width: width, alignment: .leading)

        case .playlists:
            playlistsTab(sh)
                .frame(width: width, alignment: .leading)

        case .related:
            relatedTab
                .frame(width: width, alignment: .leading)

        case .info:
            infoTab(sh)
                .frame(width: width - (C.pagePad * 2), alignment: .leading)
                .padding(.horizontal, C.pagePad)
                .frame(width: width, alignment: .leading)
        }
    }

    // MARK: - Episodes tab

    @ViewBuilder
    private func episodesTab(_ sh: ShowData, pageScrollProxy: ScrollViewProxy) -> some View {
        let seasons = sh.seasons.filter { !$0.episodes.isEmpty }
        if allEpisodes.isEmpty {
            emptyState(icon: "play.rectangle.fill", title: "No episodes yet",
                       sub: "Episodes will appear here once uploaded.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Season jump pills — only when > 1 season with content
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons) { s in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        pageScrollProxy.scrollTo(seasonAnchorId(s.id), anchor: .top)
                                    }
                                } label: {
                                    Text("Season \(s.seasonNumber)\(s.title != nil ? " — \(s.title!)" : "")")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(C.text.opacity(0.75))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(C.surface)
                                        .clipShape(Capsule())
                                        .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .padding(.bottom, 16)
                }

                if seasons.count > 1 {
                    ForEach(seasons) { season in
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Season \(season.seasonNumber)\(season.title != nil ? " — \(season.title!)" : "")")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .tracking(1.2)
                                .padding(.bottom, 12)
                                .padding(.top, 8)
                                .id(seasonAnchorId(season.id))

                            ForEach(season.episodes) { ep in
                                EpisodeRowView(
                                    ep: ep,
                                    seasonNumber: season.seasonNumber,
                                    entitlementType: sh.entitlementType,
                                    onGateCta: { presentEpisodeGateCheckout(show: sh, season: season) }
                                )
                                Divider().background(C.border.opacity(0.6))
                            }
                        }
                    }
                } else {
                    if let onlySeason = seasons.first {
                        ForEach(onlySeason.episodes) { ep in
                            EpisodeRowView(
                                ep: ep,
                                seasonNumber: onlySeason.seasonNumber,
                                entitlementType: sh.entitlementType,
                                onGateCta: { presentEpisodeGateCheckout(show: sh, season: onlySeason) }
                            )
                            Divider().background(C.border.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    // MARK: - All Videos tab

    @ViewBuilder
    private func allVideosTab(_ sh: ShowData) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let c = clips {
                if c.isEmpty {
                    emptyState(icon: "video.fill", title: "No videos yet", sub: "")
                        .padding(.horizontal, C.pagePad)
                } else {
                    if !videosList.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Videos")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .tracking(1.2)
                                .padding(.horizontal, C.pagePad)

                            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                            LazyVGrid(columns: cols, spacing: 16) {
                                ForEach(videosList) { v in
                                    NavigationLink(value: AppRoute.video(v.id)) {
                                        ShowClipCard(clip: v, style: .video)
                                    }
                                }
                            }
                            .padding(.horizontal, C.pagePad)
                        }
                    }
                    if !shortsList.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Shorts")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .tracking(1.2)
                                .padding(.horizontal, C.pagePad)

                            let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                            LazyVGrid(columns: cols, spacing: 16) {
                                ForEach(shortsList) { v in
                                    NavigationLink(value: AppRoute.short(v.id, showId: sh.id, channelId: nil)) {
                                        ShowClipCard(clip: v, style: .short)
                                    }
                                }
                            }
                            .padding(.horizontal, C.pagePad)
                        }
                    }
                }
            } else {
                ProgressView().tint(C.watch).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Playlists tab

    @ViewBuilder
    private func playlistsTab(_ sh: ShowData) -> some View {
        if let pl = playlists {
            if pl.isEmpty {
                emptyState(icon: "play.rectangle.on.rectangle", title: "No playlists yet", sub: "")
                    .padding(.horizontal, C.pagePad)
            } else {
                let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(pl) { playlist in
                        NavigationLink(value: playlist.primaryRoute) {
                            ChannelPlaylistCard2(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        } else {
            ProgressView().tint(C.watch).frame(maxWidth: .infinity)
        }
    }

    // MARK: - Related tab

    @ViewBuilder
    private var relatedTab: some View {
        if relatedShows.isEmpty {
            emptyState(icon: "tv.fill", title: "No related shows", sub: "")
                .padding(.horizontal, C.pagePad)
        } else {
            let cols = [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(relatedShows) { rs in
                    NavigationLink(value: AppRoute.show(rs.id)) {
                        RelatedShowCard(show: rs)
                    }
                }
            }
            .padding(.horizontal, C.pagePad)
        }
    }

    // MARK: - Info tab

    private func infoTab(_ sh: ShowData) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let desc = sh.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(C.text.opacity(0.80))
                    .lineSpacing(4)
            }

            let rows: [(String, String)] = [
                sh.genre         != nil ? ("Genre",    sh.genre!.capitalized)  : ("", ""),
                !sh.showType.isEmpty    ? ("Type",     showTypeLabel(sh.showType)) : ("", ""),
                !sh.language.isEmpty   ? ("Language", sh.language.capitalized) : ("", ""),
                sh.country       != nil ? ("Country",  sh.country!)             : ("", ""),
                sh.studio        != nil ? ("Studio",   sh.studio!)              : ("", ""),
                sh.contentRating != nil ? ("Rating",   sh.contentRating!)       : ("", ""),
                !isNonSerialized && sh.seasons.count > 0
                    ? ("Seasons",  "\(sh.seasons.count)")                       : ("", ""),
                !sh.tags.isEmpty        ? ("Tags",     sh.tags.joined(separator: ", ")) : ("", ""),
            ].filter { !$0.0.isEmpty }

            if !rows.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(rows, id: \.0) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.0.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(C.textMuted)
                                .tracking(1.2)
                            Text(row.1)
                                .font(.subheadline)
                                .foregroundStyle(C.text.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadError = nil

        do {
            showResp = try await APIClient.shared.fetchShow(id: showId)
        } catch {
            showResp = nil
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        // Set initial tab
        if show != nil {
            if !isNonSerialized && !allEpisodes.isEmpty {
                activeTab = .episodes
            } else if !videosList.isEmpty {
                activeTab = .videos
            } else {
                activeTab = .info
            }
        }
        isLoading = false
        Task { await loadSecondaryShowContent() }
    }

    private func loadSecondaryShowContent() async {
        async let followTask = APIClient.shared.fetchShowFollowStatus(id: showId)
        async let clipsTask = APIClient.shared.fetchShowClips(id: showId)
        async let plsTask = APIClient.shared.fetchShowPlaylists(id: showId)

        followStatus = try? await followTask
        clips = (try? await clipsTask) ?? []
        playlists = (try? await plsTask) ?? []

        if show != nil, activeTab == .info, videosList.isEmpty, clips?.isEmpty == false {
            activeTab = .shorts
        }
    }

    private var loadFailureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(C.textMuted)
            Text("Show unavailable")
                .font(.headline)
                .foregroundStyle(C.text)
            Text(loadError ?? "This show could not be loaded.")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, C.pagePad)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(C.watch)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleFollow(_ sh: ShowData) async {
        guard !followLoading else { return }
        followLoading = true
        do {
            followStatus = try await APIClient.shared.toggleShowFollow(id: sh.id)
        } catch {}
        followLoading = false
    }

    private func toggleNotify(_ sh: ShowData) async {
        guard !notifyLoading else { return }
        notifyLoading = true
        do {
            try await APIClient.shared.setShowNotify(id: sh.id, on: !notifyOn)
            followStatus = FollowStatus(subscribed: isFollowing, count: followerCount, notifyOnPublish: !notifyOn)
        } catch {}
        notifyLoading = false
    }

    private func presentEpisodeGateCheckout(show sh: ShowData, season: ShowSeasonData) {
        let entType = sh.entitlementType ?? "AVOD"
        if entType == "SVOD", let product = sh.svodProducts.first {
            presentCheckout(product: product, mode: .svod, season: nil)
        } else if (entType == "PPV" || entType == "TRANSACTIONAL"), let product = sh.ppvProducts.first {
            presentCheckout(product: product, mode: .ppv, season: season)
        } else if let url = URL(string: "\(C.baseURL)/shows/\(sh.id)") {
            openURL(url)
        }
    }

    private func presentCheckout(product: ShowProductInfo, mode: ShowCheckoutMode, season: ShowSeasonData?) {
        guard auth.isAuthenticated else {
            checkoutMessage = "Sign in to continue checkout."
            return
        }

        checkoutMode = mode
        checkoutProduct = ShowCheckoutProduct(
            id: product.id,
            name: product.name,
            type: product.type,
            price: product.price,
            currency: product.currency,
            networkId: product.networkId,
            cycleFrequency: product.cycleFrequency,
            cycleUnit: product.cycleUnit,
            seasonId: season?.id,
            scopeLabel: season.map { "Season \($0.seasonNumber)" }
        )
    }

    @MainActor
    private func runCheckout(product: ShowCheckoutProduct, mode: ShowCheckoutMode) async {
        do {
            let response: CheckoutResponse
            switch mode {
            case .svod:
                response = try await APIClient.shared.checkoutSVOD(
                    productId: product.id,
                    networkId: product.networkId
                )
            case .ppv:
                response = try await APIClient.shared.checkoutPPV(
                    productId: product.id,
                    networkId: product.networkId,
                    seasonId: product.seasonId,
                    episodeId: product.episodeId
                )
            }

            if let redirectUrl = response.redirectUrl, let url = URL(string: redirectUrl) {
                checkoutProduct = nil
                openURL(url)
                return
            }

            if response.clientSecret != nil && response.success == false {
                checkoutMessage = "This payment provider requires a hosted payment confirmation screen that is not available natively yet."
                return
            }

            checkoutProduct = nil
            checkoutMessage = mode == .svod ? "Subscription active." : "Rental active."
            await load()
        } catch {
            checkoutMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func showTypeLabel(_ type: String) -> String {
        switch type {
        case "series":       return "TV Series"
        case "movie", "film": return "Film"
        case "anime":        return "Anime"
        case "reality":      return "Reality TV"
        case "documentary":  return "Documentary"
        case "special":      return "Special"
        case "event":        return "Event"
        case "concert":      return "Concert"
        case "short":        return "Short Film"
        default:             return type.capitalized
        }
    }

    private func fmtPrice(_ cents: Int, currency: String) -> String {
        let val = Double(cents) / 100
        return String(format: "%.0f \(currency)", val)
    }

    private func emptyState(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            if !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Checkout

private enum ShowCheckoutMode {
    case svod, ppv
}

private struct ShowCheckoutProduct: Identifiable {
    let id: String
    let name: String
    let type: String
    let price: Int?
    let currency: String?
    let networkId: String
    let cycleFrequency: Int?
    let cycleUnit: String?
    let seasonId: String?
    var episodeId: String? = nil
    let scopeLabel: String?
}

private struct ShowCheckoutSheet: View {
    let product: ShowCheckoutProduct
    let mode: ShowCheckoutMode
    let onCancel: () -> Void
    let onConfirm: () async -> Void

    @State private var isLoading = false

    private var isSvod: Bool { mode == .svod }
    private var accent: Color { isSvod ? C.listen : Color(hex: "#F59E0B") }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Capsule()
                    .fill(accent)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 14) {
                    Image(systemName: isSvod ? "rectangle.stack.badge.play" : "ticket")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 52, height: 52)
                        .background(accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(accent.opacity(0.30), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isSvod ? "Subscribe" : "Rent")
                            .font(.system(size: 11, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(accent)
                        Text(product.name)
                            .font(.headline)
                            .foregroundStyle(C.text)
                            .lineLimit(2)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let scopeLabel = product.scopeLabel, !isSvod {
                        checkoutRow(label: "Content", value: scopeLabel)
                    }
                    if let price = product.price {
                        checkoutRow(label: isSvod ? "Plan" : "Rental", value: priceText(price, currency: product.currency) + cycleText)
                    }
                    checkoutRow(label: "Provider", value: "Secure checkout")
                }
                .padding(14)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: C.cardRadius)
                        .stroke(C.border, lineWidth: 1)
                }

                Text(isSvod ? "Your subscription unlocks eligible content for this network." : "Your rental unlocks the selected season or episode according to the rental terms.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                    .disabled(isLoading)

                    Button {
                        Task {
                            isLoading = true
                            await onConfirm()
                            isLoading = false
                        }
                    } label: {
                        if isLoading {
                            ProgressView().tint(.black)
                        } else {
                            Text(isSvod ? "Confirm Subscribe" : "Confirm Rent")
                        }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(accent)
                    .clipShape(Capsule())
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal, C.pagePad)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private var cycleText: String {
        guard isSvod, let frequency = product.cycleFrequency, let unit = product.cycleUnit else { return "" }
        let lower = unit.lowercased()
        if frequency == 1 { return " / \(lower)" }
        return " / \(frequency) \(lower)s"
    }

    private func checkoutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(C.textMuted)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func priceText(_ cents: Int, currency: String?) -> String {
        let value = Double(cents) / 100
        let code = currency ?? "USD"
        return String(format: "%.2f %@", value, code)
    }
}

// MARK: - EpisodeRowView

private struct EpisodeRowView: View {

    let ep: ShowEpisodeItem
    let seasonNumber: Int
    let entitlementType: String?
    let onGateCta: () -> Void

    @State private var descExpanded = false

    private var premiereAt: String? {
        ep.schedule?.windows.first(where: { $0.scope == "worldwide" })?.premiereAt
            ?? ep.schedule?.windows.first?.premiereAt
    }
    private var isPremiereDue: Bool {
        guard let premiereAt, let date = parseDate(premiereAt) else { return false }
        return date <= Date()
    }
    private var isComingSoon: Bool {
        ep.comingSoon && !isPremiereDue
    }
    private var isAvailable: Bool {
        (ep.isPlayable || ep.videoUrl != nil) && !isComingSoon
    }
    private var isGated: Bool {
        !isAvailable && !isComingSoon && (entitlementType == "SVOD" || entitlementType == "PPV")
    }

    var body: some View {
        Group {
            if isAvailable {
                NavigationLink(value: AppRoute.episode(ep.id)) {
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .buttonStyle(.plain)
        .opacity(!isAvailable && !isComingSoon ? 0.5 : 1)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thumbnail
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: C.mediaURL(ep.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    C.surface
                }
                .frame(width: 140, height: 78) // ~16:9
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                if let dur = ep.duration, dur > 0, !isComingSoon {
                    Text(fmtDuration(dur))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }

                if isComingSoon {
                    Color.black.opacity(0.55)
                        .overlay {
                            Text("Coming\nSoon")
                                .font(.system(size: 10, weight: .bold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isGated {
                    Color.black.opacity(0.62)
                        .overlay {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 140, height: 78)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text("S\(seasonNumber)E\(ep.episodeNumber)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(C.textMuted)

                Text(ep.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)

                if let desc = ep.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(descExpanded ? nil : 3)
                }

                if isGated {
                    Button {
                        onGateCta()
                    } label: {
                        Label(entitlementType == "SVOD" ? "Subscribe to watch" : "Rent Season \(seasonNumber)", systemImage: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(entitlementType == "SVOD" ? C.listen : .orange)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }

                // Coming soon date
                if isComingSoon {
                    if let premiere = premiereAt {
                        Text("Premieres \(fmtDate(premiere))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.watch)
                    } else {
                        Text("Coming soon")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 12)
    }

    private func fmtDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func fmtDate(_ iso: String) -> String {
        guard let d = parseDate(iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: d)
    }

    private func parseDate(_ iso: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: iso) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: iso) { return date }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        return df.date(from: iso)
    }
}

// MARK: - ShowClipCard

private struct ShowClipCard: View {
    enum CardStyle {
        case video
        case short

        var aspectRatio: CGFloat {
            16.0 / 9.0
        }
    }

    let clip: ShowClip
    let style: CardStyle

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = width / style.aspectRatio

            ZStack(alignment: .bottomTrailing) {
                C.surface

                if let url = C.mediaURL(clip.thumbnailUrl) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        C.surface
                    }
                    .frame(width: width, height: height)
                    .clipped()
                }

                if let dur = clip.duration, dur > 0 {
                    Text(fmtDuration(dur))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
        .aspectRatio(style.aspectRatio, contentMode: .fit)
    }

    private func fmtDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - RelatedShowCard

private struct RelatedShowCard: View {
    let show: RelatedShow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                C.surface
                if let url = C.mediaURL(show.coverUrl) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        C.surface
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(show.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
        }
    }
}

// MARK: - ChannelPlaylistCard2 (reused playlist card for ShowView)

private struct ChannelPlaylistCard2: View {
    let playlist: ChannelPlaylist

    private var thumbnails: [String] {
        playlist.items.compactMap { $0.video?.thumbnailUrl }
    }
    private var count: Int { playlist._count.items }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                mosaicThumbnail
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.68)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                playlistCountBadge
                    .padding(8)
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 34, alignment: .topLeading)

                HStack(spacing: 5) {
                    MediaverseIcon(name: "playlist", fallbackSystemName: "play.rectangle.on.rectangle")
                        .frame(width: 11, height: 11)
                    Text("Playlist")
                    Text("·")
                    Text("\(count)")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var playlistCountBadge: some View {
        let itemName = playlist.type == "short" ? "short" : "video"

        return Text("\(count) \(itemName)\(count == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.76))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var mosaicThumbnail: some View {
        let visibleThumbs = Array(thumbnails.prefix(4))

        if visibleThumbs.count >= 4 {
            GeometryReader { geo in
                let cellWidth = geo.size.width / 2
                let cellHeight = geo.size.height / 2

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mosaicImage(visibleThumbs[0])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(visibleThumbs[1])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                    HStack(spacing: 0) {
                        mosaicImage(visibleThumbs[2])
                            .frame(width: cellWidth, height: cellHeight)
                        mosaicImage(visibleThumbs[3])
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
        } else if let t = visibleThumbs.first {
            mosaicImage(t)
        } else {
            C.surface
                .overlay {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(C.textMuted)
                }
        }
    }

    private func mosaicImage(_ url: String) -> some View {
        AsyncImage(url: C.mediaURL(url)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            C.surface
        }
        .clipped()
    }
}

private extension ShowEpisodeItem {
    var isPlayable: Bool {
        videoUrl != nil && !comingSoon
    }
}
