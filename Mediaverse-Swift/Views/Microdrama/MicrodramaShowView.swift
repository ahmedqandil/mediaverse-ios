import SwiftUI
import AVKit

/// Microdrama series detail page — episode list with access badges + ad-unlock flow.
/// Mirrors /src/app/microdramas/[showId]/MicrodramaShowClient.tsx
struct MicrodramaShowView: View {

    let showId: String

    @State private var show: MicrodramaShowDetail?
    @State private var episodes = [MicrodramaEpisode]()
    @State private var config: MicrodramaConfig?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var adModal: MicrodramaEpisode? = nil
    @State private var adGranting = false
    @State private var adGrantedEpisodes = Set<String>()

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(C.watch)
            } else if let err = errorMsg {
                errorState(err)
            } else if let show {
                content(show)
            }
        }
        .navigationTitle(show?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $adModal) { ep in
            AdUnlockSheet(episode: ep) { granted in
                if granted { adGrantedEpisodes.insert(ep.id) }
            }
        }
    }

    // MARK: - Main content

    private func content(_ show: MicrodramaShowDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero banner
                hero(show)

                // Access lines (e.g. "First 3 episodes are free")
                accessLines
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 16)

                // Episode list
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { ep in
                        EpisodeAccessRow(
                            ep: ep,
                            showId: showId,
                            isAdGranted: adGrantedEpisodes.contains(ep.id)
                        ) {
                            adModal = ep
                        }
                        Divider().background(C.border)
                            .padding(.leading, C.pagePad + 60)
                    }
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Hero

    private func hero(_ show: MicrodramaShowDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: C.mediaURL(show.bannerUrl ?? show.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("📱 Microdrama")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.15)).clipShape(Capsule())
                    if let g = show.genre {
                        Text(g)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.1)).clipShape(Capsule())
                    }
                }
                Text(show.title)
                    .font(.title2.bold()).foregroundStyle(.white).lineLimit(2)
                if let desc = show.description {
                    Text(desc)
                        .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(3)
                }

                // CTA
                NavigationLink(value: AppRoute.microdramaWatch(showId)) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Watch Now")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.white).clipShape(Capsule())
                }
                .padding(.top, 4)
            }
            .padding(C.pagePad)
        }
    }

    // MARK: - Access summary lines

    @ViewBuilder
    private var accessLines: some View {
        if let cfg = config {
            VStack(alignment: .leading, spacing: 4) {
                if cfg.freeEpisodeCount > 0 {
                    Label("First \(cfg.freeEpisodeCount) episode\(cfg.freeEpisodeCount > 1 ? "s" : "") are free",
                          systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(hex: "#10B981"))
                }
                if cfg.adUnlockEnabled {
                    Label("Watch a short ad to unlock episodes \(cfg.adUnlockStartEpisode)+",
                          systemImage: "play.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(C.textMuted)
                }
            }
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
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(C.textMuted)
            Text(msg).foregroundStyle(C.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Episode row

private struct EpisodeAccessRow: View {
    let ep: MicrodramaEpisode
    let showId: String
    let isAdGranted: Bool
    let onWatchAd: () -> Void

    private var effectiveState: String {
        if isAdGranted && ep.accessState == "ad_unlock" { return "free" }
        return ep.accessState
    }
    private var canPlay: Bool { effectiveState == "free" || effectiveState == "svod" || effectiveState == "ppv" }
    private var badge: (label: String, color: Color) {
        switch ep.accessState {
        case "free":      return ("FREE", Color(hex: "#10B981"))
        case "svod":      return ("SUB",  Color(hex: "#7C3AED"))
        case "ppv":       return ("RENT", Color(hex: "#F59E0B"))
        case "ad_unlock": return ("AD",   Color(hex: "#FBBF24"))
        default:          return ("🔒",   Color.white.opacity(0.3))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Portrait thumbnail
            ZStack {
                AsyncImage(url: C.mediaURL(ep.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                    Text("\(ep.episodeNumber)")
                        .font(.caption.bold())
                        .foregroundStyle(Color.white.opacity(0.2))
                }
                .frame(width: 52, height: 92) // 9:16 portrait
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if !canPlay {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("E\(ep.episodeNumber)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(C.watch)
                    Text(badge.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(badge.color.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(ep.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(canPlay ? C.text : C.textMuted)
                    .lineLimit(2)
                if let dur = ep.duration {
                    Text(formatDuration(dur))
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
            }

            Spacer()

            // Action button
            if canPlay {
                NavigationLink(value: AppRoute.microdramaWatchEp(showId, ep.episodeNumber)) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(C.watch)
                }
            } else if ep.accessState == "ad_unlock" && ep.adUnlockAvailable == true {
                Button(action: onWatchAd) {
                    Text("Watch Ad")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "#FBBF24"))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, C.pagePad)
        .padding(.vertical, 10)
        .opacity(canPlay ? 1 : 0.65)
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return "\(m):\(String(format: "%02d", sec))"
    }
}

// MARK: - Ad unlock sheet (mock 5s ad)

private struct AdUnlockSheet: View {
    let episode: MicrodramaEpisode
    let onComplete: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var countdown  = 5
    @State private var isUnlocking = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // Fake ad space
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#4C1D95"), Color(hex: "#1E1B4B")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    VStack(spacing: 8) {
                        Text("📱").font(.system(size: 48))
                        Text("Advertisement").font(.caption).foregroundStyle(.white.opacity(0.6))
                        Text("Your ad plays here").font(.caption2).foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)

                VStack(spacing: 16) {
                    Text(countdown > 0
                         ? "You can skip in \(countdown)s"
                         : "Ad complete — your episode is unlocked!")
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)

                    if countdown == 0 {
                        Button {
                            Task { await grantUnlock() }
                        } label: {
                            HStack {
                                if isUnlocking { ProgressView().tint(.black) }
                                Text("Watch Episode")
                                    .font(.headline.bold())
                                    .foregroundStyle(.black)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(Capsule())
                        }
                        .disabled(isUnlocking)
                    } else {
                        Text("Skip in \(countdown)s")
                            .font(.headline.bold())
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())

                        Button("Cancel") { dismiss() }
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                    }
                }
                .padding(C.pagePad)
                .background(C.surface)
            }
        }
        .onAppear { startCountdown() }
        .onDisappear { timer?.invalidate() }
    }

    private func startCountdown() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if countdown > 0 { countdown -= 1 } else { timer?.invalidate() }
        }
    }

    private func grantUnlock() async {
        isUnlocking = true
        do {
            let resp = try await APIClient.shared.adUnlock(episodeId: episode.id)
            onComplete(resp.granted)
        } catch {
            onComplete(false)
        }
        dismiss()
    }
}
