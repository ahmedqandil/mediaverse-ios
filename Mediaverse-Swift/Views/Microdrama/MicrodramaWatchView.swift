import SwiftUI
import AVKit
import UIKit

/// Full-screen vertical microdrama player.
/// Episodes are swiped vertically (like TikTok/Reels).
/// Mirrors /src/app/microdramas/watch/[showId]/page.tsx + MicrodramaPlayer component.
struct MicrodramaWatchView: View {

    let showId: String
    var startEpisodeNumber: Int = 1

    @State private var episodes   = [MicrodramaEpisode]()
    @State private var show: MicrodramaShowDetail?
    @State private var config: MicrodramaConfig?
    @State private var offers: MicrodramaOffers?
    @State private var currentIdx = 0
    @State private var isLoading  = true
    @State private var errorMsg: String?
    @State private var playerItems = [Int: AVPlayerItem]()
    @State private var showEpisodeDrawer = false
    @State private var currentEpisodeID: String?

    @Environment(\.dismiss) private var dismiss
    private var currentEp: MicrodramaEpisode? { episodes.indices.contains(currentIdx) ? episodes[currentIdx] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                loadingView
            } else if let err = errorMsg {
                errorView(err)
            } else if episodes.isEmpty {
                emptyView
            } else {
                playerStack
            }
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .disablesInteractiveSwipeBack()
        .task { await load() }
        .sheet(isPresented: $showEpisodeDrawer) {
            MicrodramaEpisodesDrawer(
                episodes: episodes,
                currentEpisodeId: currentEp?.id,
                onSelect: { ep in
                    if let idx = episodes.firstIndex(where: { $0.id == ep.id }) {
                        currentIdx = idx
                        currentEpisodeID = ep.id
                    }
                    showEpisodeDrawer = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black.opacity(0.92))
        }
    }

    // MARK: - Player stack (vertical swipe)

    private var playerStack: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { idx, ep in
                            EpisodePlayerSlide(
                                episode: ep,
                                show: show,
                                totalEpisodes: episodes.count,
                                isActive: ep.id == currentEpisodeID,
                                shouldPrepare: abs(idx - currentIdx) <= 1,
                                bottomChromeHeight: 78 + geo.safeAreaInsets.bottom,
                                onBack: { dismiss() },
                                onPrev: idx > 0 ? { selectEpisode(at: idx - 1) } : nil,
                                onNext: idx < episodes.count - 1 ? { selectEpisode(at: idx + 1) } : nil,
                                offers: offers
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ep.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentEpisodeID)
                .ignoresSafeArea()
                .onAppear {
                    if currentEpisodeID == nil {
                        currentEpisodeID = currentEp?.id ?? episodes.first?.id
                    }
                }
                .onChange(of: currentEpisodeID) { _, id in
                    guard let id,
                          let idx = episodes.firstIndex(where: { $0.id == id }) else { return }
                    currentIdx = idx
                }
                .onChange(of: currentIdx) { _, idx in
                    guard episodes.indices.contains(idx), currentEpisodeID != episodes[idx].id else { return }
                    currentEpisodeID = episodes[idx].id
                }

                if let currentEp {
                    episodesBottomBar(currentEp)
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom + 12, 24))
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // Jump to start episode
            if let idx = episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
                selectEpisode(at: idx)
            } else if currentEpisodeID == nil {
                selectEpisode(at: 0)
            }
        }
    }

    // MARK: - Loading / error / empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading series…")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(msg).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Go back") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text("No episodes available yet").foregroundStyle(.white.opacity(0.6))
            Button("Go back") { dismiss() }.foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        do {
            let resp = try await APIClient.shared.fetchMicrodramaEpisodes(showId: showId)
            show     = resp.show
            config   = resp.config
            episodes = resp.episodes
            offers = resp.offers
            if let idx = resp.episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
                currentIdx = idx
                currentEpisodeID = resp.episodes[idx].id
            } else if let first = resp.episodes.first {
                currentIdx = 0
                currentEpisodeID = first.id
            }
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    private func episodesBottomBar(_ episode: MicrodramaEpisode) -> some View {
        Button {
            showEpisodeDrawer = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                Text("Episodes")
                    .font(.subheadline.weight(.semibold))
                Text("Ep \(episode.episodeNumber)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text("\(currentIdx + 1) / \(episodes.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: 392)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func selectEpisode(at index: Int) {
        guard episodes.indices.contains(index) else { return }
        currentIdx = index
        currentEpisodeID = episodes[index].id
    }

}

// MARK: - Single episode slide

private struct EpisodePlayerSlide: View {

    let episode: MicrodramaEpisode
    let show: MicrodramaShowDetail?
    let totalEpisodes: Int
    let isActive: Bool
    let shouldPrepare: Bool
    let bottomChromeHeight: CGFloat
    let onBack: () -> Void
    let onPrev: (() -> Void)?
    let onNext: (() -> Void)?
    let offers: MicrodramaOffers?

    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var progressTask: Task<Void, Never>?
    @State private var showComments = false
    @State private var isLiked = false
    @State private var isSaved = false
    @State private var endObserver: NSObjectProtocol?
    @AppStorage("playerMuted") private var playerMuted = false

    private var canPlay: Bool {
        episode.videoUrl != nil
    }

    private var paywallMessage: String {
        if offers?.canSubscribe == true || offers?.canRent == true {
            return "Subscribe or rent this episode to continue watching."
        }
        return "This episode is not available to purchase yet."
    }

    private var showSubscribeButton: Bool {
        offers?.canSubscribe == true
    }

    private var showRentButton: Bool {
        offers?.canRent == true
    }

    private var channelTitle: String? {
        let name = show?.network?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private var showArtworkUrl: String? {
        show?.coverUrl ?? show?.bannerUrl ?? episode.thumbnailUrl
    }

    private var showTitleText: String {
        let value = show?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return "Microdrama"
    }

    private var episodeDescription: String? {
        let value = episode.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : show?.description
    }

    private var showEpisodeTitle: String {
        let showTitle = show?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeTitle = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let showTitle, !showTitle.isEmpty {
            return "\(showTitle) · E\(episode.episodeNumber) · \(episodeTitle)"
        }
        return "E\(episode.episodeNumber) · \(episodeTitle)"
    }

    var body: some View {
        ZStack {
            Color.black

            if canPlay, let player {
                // AVPlayer video (fills screen, no controls — swipe to navigate)
                AVPlayerViewRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                // Poster / locked state
                CachedRemoteImage(
                    url: C.mediaURL(episode.thumbnailUrl),
                    targetSize: CGSize(width: 390, height: 844)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(
                        colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()

                if !canPlay {
                    lockedOverlay
                }
            }

            // Prev / next hit zones
            HStack {
                Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onTapGesture { onPrev?() }
                Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onTapGesture { onNext?() }
            }
            .allowsHitTesting(canPlay)

            GeometryReader { geo in
                let safeTop = max(geo.safeAreaInsets.top, 44)
                let progressControlHeight: CGFloat = 16
                let playerVerticalGap: CGFloat = 12
                let reservedBottom = bottomChromeHeight + progressControlHeight + playerVerticalGap
                let horizontalInset: CGFloat = 24
                let rightRailInset: CGFloat = 94

                // HUD overlay
                VStack {
                    topBar(topInset: safeTop)
                    Spacer()
                    bottomInfo(
                        bottomInset: reservedBottom,
                        horizontalInset: horizontalInset,
                        trailingInset: rightRailInset
                    )
                }

                rightRail
                    .padding(.trailing, horizontalInset)
                    .padding(.bottom, reservedBottom + 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                microdramaProgressBar(width: geo.size.width)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, bottomChromeHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .sheet(isPresented: $showComments) {
            StandardCommentsSheet(
                target: .episode(episode.id),
                title: "Comments"
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: episode.id + "_\(shouldPrepare)") {
            if shouldPrepare {
                await setupPlayerIfNeeded(autoplay: isActive)
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                if let player {
                    player.seek(to: .zero)
                    player.isMuted = playerMuted
                    player.play()
                    startProgressTracking(for: player)
                } else {
                    Task { await setupPlayerIfNeeded(autoplay: true) }
                }
            } else {
                stopPlayback()
            }
        }
        .onChange(of: shouldPrepare) { _, prepare in
            if prepare {
                Task { await setupPlayerIfNeeded(autoplay: isActive) }
            } else if !isActive {
                stopPlayback(resetPlayer: true)
            }
        }
        .onDisappear {
            stopPlayback(resetPlayer: true)
        }
    }

    @MainActor
    private func setupPlayerIfNeeded(autoplay: Bool) async {
        guard shouldPrepare,
              canPlay,
              player == nil,
              let url = C.mediaURL(episode.videoUrl) else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.isMuted = playerMuted
        newPlayer.volume = 1
        player = newPlayer
        if autoplay {
            newPlayer.play()
            startProgressTracking(for: newPlayer)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            onNext?()
        }
    }

    @MainActor
    private func startProgressTracking(for player: AVPlayer) {
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled, isActive {
                if let item = player.currentItem {
                    let current = player.currentTime().seconds
                    let total = item.duration.seconds
                    if current.isFinite, total.isFinite, total > 0 {
                        await MainActor.run {
                            progress = (current / total).clampedProgress
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func microdramaProgressBar(width: CGFloat) -> some View {
        let safeWidth = max(1, width - 48)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
                .frame(height: 4)
            Capsule().fill(C.watch)
                .frame(width: safeWidth * CGFloat(progress.clampedProgress), height: 4)
            Circle()
                .fill(C.watch)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .offset(x: max(0, safeWidth * CGFloat(progress.clampedProgress) - 6))
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    seekMicrodrama(to: Double(value.location.x / safeWidth), commit: false)
                }
                .onEnded { value in
                    seekMicrodrama(to: Double(value.location.x / safeWidth), commit: true)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress.clampedProgress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                seekMicrodrama(to: progress + 0.05, commit: true)
            case .decrement:
                seekMicrodrama(to: progress - 0.05, commit: true)
            default:
                break
            }
        }
    }

    private func seekMicrodrama(to rawProgress: Double, commit: Bool) {
        let targetProgress = rawProgress.clampedProgress
        progress = targetProgress
        guard commit, let player, let item = player.currentItem else { return }
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let target = CMTime(seconds: total * targetProgress, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if isActive {
            player.play()
        }
    }

    @MainActor
    private func stopPlayback(resetPlayer: Bool = false) {
        progressTask?.cancel()
        progressTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        if resetPlayer {
            player = nil
            progress = 0
        }
    }

    // MARK: - Top bar

    private func topBar(topInset: CGFloat) -> some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }

            Spacer()

            Text("Ep \(episode.episodeNumber) of \(totalEpisodes)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.black.opacity(0.42), in: Capsule())

            Spacer()

            Button {
                playerMuted.toggle()
                player?.isMuted = playerMuted
            } label: {
                Image(systemName: playerMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 8)
    }

    // MARK: - Bottom info

    private func bottomInfo(bottomInset: CGFloat, horizontalInset: CGFloat, trailingInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                microdramaAvatar

                VStack(alignment: .leading, spacing: 1) {
                    Text(showTitleText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let channelTitle {
                        Text(channelTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Button {} label: {
                    Text("Follow")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(C.watch)
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .overlay { Capsule().stroke(C.watch, lineWidth: 1) }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            Text("E\(episode.episodeNumber) · \(episode.title)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if let description = episodeDescription {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            if let dur = episode.duration {
                Text(formatDur(dur))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(.leading, horizontalInset)
        .padding(.trailing, horizontalInset + trailingInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.76)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var microdramaAvatar: some View {
        Group {
            if let url = C.mediaURL(showArtworkUrl) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: 34, height: 34)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.12)
                }
            } else {
                Text(String((showTitleText.first ?? "?").uppercased()))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(C.watch)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.55), lineWidth: 2) }
    }

    private var rightRail: some View {
        VStack(alignment: .center, spacing: 18) {
            railButton(
                icon: isLiked ? "heart-filled" : "heart",
                fallback: isLiked ? "heart.fill" : "heart",
                color: isLiked ? Color(red: 1, green: 0.28, blue: 0.34) : .white,
                background: isLiked ? Color(red: 1, green: 0.28, blue: 0.34).opacity(0.35) : .black.opacity(0.35),
                label: "Like",
                labelColor: isLiked ? Color(red: 1, green: 0.28, blue: 0.34) : .white.opacity(0.85)
            ) { isLiked.toggle() }

            railButton(icon: "message-square", fallback: "bubble.left", label: "Comment") {
                showComments = true
            }

            railButton(icon: "share", fallback: "square.and.arrow.up", label: "Share") {
                shareEpisode()
            }

            railButton(
                icon: "bookmark",
                fallback: isSaved ? "bookmark.fill" : "bookmark",
                color: isSaved ? C.watch : .white,
                background: isSaved ? C.watch.opacity(0.30) : .black.opacity(0.35),
                label: "Save",
                labelColor: isSaved ? C.watch : .white.opacity(0.85)
            ) { isSaved.toggle() }
        }
    }

    private func railButton(
        icon: String,
        fallback: String,
        color: Color = .white,
        background: Color = .black.opacity(0.35),
        label: String?,
        labelColor: Color = .white.opacity(0.85),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                MediaverseIcon(name: icon, fallbackSystemName: fallback)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(color)
                    .frame(width: 50, height: 50)
                    .background(background)
                    .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
                    .clipShape(Circle())
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func shareEpisode() {
        guard let url = URL(string: "\(C.baseURL)/microdramas/watch/\(show?.id ?? episode.id)?episode=\(episode.episodeNumber)") else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.presentFromRoot()
    }

    // MARK: - Locked overlay

    private var lockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.78)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Episode \(episode.episodeNumber) is locked")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(paywallMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                VStack(spacing: 10) {
                    if showSubscribeButton || showRentButton {
                        HStack(spacing: 10) {
                            if showSubscribeButton {
                                Button {} label: {
                                    Text("Subscribe")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.black)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 52)
                                        .background(.white, in: Capsule())
                                }
                            }

                            if showRentButton {
                                Button {} label: {
                                    Text("Rent episode")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 52)
                                        .background(.white.opacity(0.14), in: Capsule())
                                        .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 330)
            }
            .padding()
        }
    }

    private func formatDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

// MARK: - AVPlayer SwiftUI bridge

@MainActor
private struct AVPlayerViewRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = AVPlayerUIView()
        view.player = player
        player.play()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerView = uiView as? AVPlayerUIView {
            if playerView.player !== player {
                playerView.player = player
                player.play()
            }
        }
    }
}

private class AVPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set {
            (layer as? AVPlayerLayer)?.player = newValue
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        }
    }
}

private extension Double {
    var clampedProgress: Double {
        guard isFinite else { return 0 }
        return min(max(self, 0), 1)
    }
}

// MARK: - Episodes drawer

private struct MicrodramaEpisodesDrawer: View {
    let episodes: [MicrodramaEpisode]
    let currentEpisodeId: String?
    let onSelect: (MicrodramaEpisode) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        Button {
                            onSelect(episode)
                        } label: {
                            MicrodramaEpisodeDrawerRow(
                                episode: episode,
                                isCurrent: episode.id == currentEpisodeId
                            )
                        }
                        Divider()
                            .background(.white.opacity(0.08))
                            .padding(.leading, 82)
                    }
                }
                .padding(.top, 10)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

private struct MicrodramaEpisodeDrawerRow: View {
    let episode: MicrodramaEpisode
    let isCurrent: Bool

    private var isLocked: Bool {
        episode.videoUrl == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(episode.thumbnailUrl),
                    targetSize: CGSize(width: 50, height: 89)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 50, height: 89)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Image(systemName: isLocked ? "lock.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.68), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ep \(episode.episodeNumber)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isCurrent ? C.watch : .white.opacity(0.62))

                Text(episode.title)
                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let duration = episode.duration {
                    Text(formatDur(duration))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.46))
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.watch)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? C.watch.opacity(0.12) : .clear)
    }

    private func formatDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}
