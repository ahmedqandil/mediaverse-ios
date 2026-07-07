import SwiftUI
import AVKit

/// Full-screen vertical microdrama player.
/// Episodes are swiped vertically (like TikTok/Reels).
/// Mirrors /src/app/microdramas/watch/[showId]/page.tsx + MicrodramaPlayer component.
struct MicrodramaWatchView: View {

    let showId: String
    var startEpisodeNumber: Int = 1

    @State private var episodes   = [MicrodramaEpisode]()
    @State private var show: MicrodramaShowDetail?
    @State private var config: MicrodramaConfig?
    @State private var currentIdx = 0
    @State private var isLoading  = true
    @State private var errorMsg: String?
    @State private var adModal: MicrodramaEpisode?
    @State private var adGrantedEpisodes = Set<String>()
    @State private var playerItems = [Int: AVPlayerItem]()

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
        .statusBar(hidden: true)
        .navigationBarHidden(true)
        .task { await load() }
        .sheet(item: $adModal) { ep in
            AdWatchSheet(episode: ep) { granted in
                if granted {
                    adGrantedEpisodes.insert(ep.id)
                    Task { await reloadAfterAdUnlock(episodeId: ep.id) }
                }
            }
        }
    }

    // MARK: - Player stack (vertical swipe)

    private var playerStack: some View {
        GeometryReader { geo in
            TabView(selection: $currentIdx) {
                ForEach(Array(episodes.enumerated()), id: \.offset) { idx, ep in
                    EpisodePlayerSlide(
                        episode: ep,
                        show: show,
                        isActive: idx == currentIdx,
                        isAdGranted: adGrantedEpisodes.contains(ep.id),
                        onBack: { dismiss() },
                        onWatchAd: { adModal = ep },
                        onPrev: idx > 0 ? { currentIdx = idx - 1 } : nil,
                        onNext: idx < episodes.count - 1 ? { currentIdx = idx + 1 } : nil
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onAppear {
            // Jump to start episode
            if let idx = episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
                currentIdx = idx
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
            Text("⚠️").font(.system(size: 40))
            Text(msg).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Go back") { dismiss() }
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Text("📭").font(.system(size: 40))
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
            if let idx = resp.episodes.firstIndex(where: { $0.episodeNumber == startEpisodeNumber }) {
                currentIdx = idx
            }
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    private func reloadAfterAdUnlock(episodeId: String) async {
        guard let currentEpisode = currentEp else { return }
        do {
            let resp = try await APIClient.shared.fetchMicrodramaEpisodes(showId: showId)
            show = resp.show
            config = resp.config
            episodes = resp.episodes
            if let idx = resp.episodes.firstIndex(where: { $0.id == episodeId }) {
                currentIdx = idx
            } else if let idx = resp.episodes.firstIndex(where: { $0.id == currentEpisode.id }) {
                currentIdx = idx
            }
        } catch {}
    }
}

// MARK: - Single episode slide

private struct EpisodePlayerSlide: View {

    let episode: MicrodramaEpisode
    let show: MicrodramaShowDetail?
    let isActive: Bool
    let isAdGranted: Bool
    let onBack: () -> Void
    let onWatchAd: () -> Void
    let onPrev: (() -> Void)?
    let onNext: (() -> Void)?

    @State private var player: AVPlayer?
    @AppStorage("playerMuted") private var playerMuted = false

    private var canPlay: Bool {
        let state = episode.accessState
        return state == "free" || state == "svod" || state == "ppv" ||
               (state == "ad_unlock" && isAdGranted)
    }
    private var showAdUnlock: Bool {
        episode.accessState == "ad_unlock" && !isAdGranted && episode.adUnlockAvailable == true
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
                AsyncImage(url: C.mediaURL(episode.thumbnailUrl)) { img in
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

            // HUD overlay
            VStack {
                topBar
                Spacer()
                bottomInfo
            }
            .ignoresSafeArea(edges: .bottom)

            // Prev / next hit zones
            HStack {
                Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onTapGesture { onPrev?() }
                Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onTapGesture { onNext?() }
            }
            .allowsHitTesting(canPlay)
        }
        .task(id: episode.id + "_\(isAdGranted)_\(isActive)") {
            await setupPlayerIfNeeded()
        }
        .onChange(of: isActive) { _, active in
            if active {
                if let player {
                    player.seek(to: .zero)
                    player.play()
                } else {
                    Task { await setupPlayerIfNeeded() }
                }
            } else {
                player?.pause()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    @MainActor
    private func setupPlayerIfNeeded() async {
        guard isActive,
              canPlay,
              player == nil,
              let url = C.mediaURL(episode.videoUrl) else { return }
        let newPlayer = AVPlayer(url: url)
        newPlayer.isMuted = playerMuted
        newPlayer.volume = 1
        player = newPlayer
        newPlayer.play()
    }

    // MARK: - Top bar

    private var topBar: some View {
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
            if let title = show?.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            // Ep counter
            Text("E\(episode.episodeNumber)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(10)
                .background(Color.black.opacity(0.4))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)  // safe area
    }

    // MARK: - Bottom info

    private var bottomInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("E\(episode.episodeNumber) · \(episode.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                if let dur = episode.duration {
                    Text(formatDur(dur))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            // Swipe hint
            if onNext != nil {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                    Text("Swipe for next episode")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Locked overlay

    private var lockedOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 16) {
                if showAdUnlock {
                    VStack(spacing: 12) {
                        Text("📺").font(.system(size: 44))
                        Text("Watch a short ad to unlock this episode")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Button(action: onWatchAd) {
                            Text("Watch Ad")
                                .font(.subheadline.bold())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(Color(hex: "#FBBF24"))
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(episode.accessState == "svod" ? "Subscription required" : "Rental required")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
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
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        }
    }
}

// MARK: - Ad watch sheet (reused from MicrodramaShowView style)

private struct AdWatchSheet: View {
    let episode: MicrodramaEpisode
    let onComplete: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var countdown   = 5
    @State private var isUnlocking = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    VStack(spacing: 8) {
                        Text("📱").font(.system(size: 48))
                        Text("Advertisement").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 220)

                VStack(spacing: 16) {
                    Text(countdown > 0 ? "You can skip in \(countdown)s" : "Ad complete!")
                        .font(.subheadline).foregroundStyle(C.textMuted)

                    if countdown == 0 {
                        Button {
                            Task { await unlock() }
                        } label: {
                            Group {
                                if isUnlocking { ProgressView().tint(.black) }
                                else { Text("Watch Episode").font(.headline.bold()) }
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(.white).clipShape(Capsule())
                        }
                        .disabled(isUnlocking)
                    } else {
                        Text("Skip in \(countdown)s")
                            .font(.headline.bold()).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(.white.opacity(0.1)).clipShape(Capsule())
                        Button("Cancel") { dismiss() }
                            .font(.subheadline).foregroundStyle(C.textMuted)
                    }
                }
                .padding(C.pagePad).background(C.surface)
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                if countdown > 0 { countdown -= 1 } else { timer?.invalidate() }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func unlock() async {
        isUnlocking = true
        do {
            let resp = try await APIClient.shared.adUnlock(episodeId: episode.id)
            onComplete(resp.granted)
        } catch { onComplete(false) }
        dismiss()
    }
}
