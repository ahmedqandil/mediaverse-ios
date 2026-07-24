import SwiftUI
import AVKit
import UIKit

struct ClipPlaybackRange: Equatable {
    let markIn: Double
    let markOut: Double
}

typealias ClipRequestHandler = (Int, Int, String, Bool, Data?) async throws -> Void

struct PlayerRelatedItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
}

struct WatchPlayerChrome<MarkerOverlay: View>: View {
    let player: AVPlayer
    let heatmapBuckets: [Int]
    let likedSeconds: [Int]
    let isAuthenticated: Bool
    let onLikeMoment: ((Int) -> Void)?
    let showSpoilerToggle: Bool
    let onClipRequest: ClipRequestHandler?
    @Binding private var activeClipRange: ClipPlaybackRange?
    var markers: MarkerOverlay
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onFullscreen: () -> Void
    let isFullscreenPresentation: Bool
    let relatedItems: [PlayerRelatedItem]
    let onSelectRelated: ((PlayerRelatedItem) -> Void)?
    let adBreaks: [AdBreak]
    let watchedAdBreakIds: Set<String>
    let onAdBreakRequested: ((AdBreak, Double?) -> Void)?
    let knownDuration: Double?
    let controlsInitiallyVisible: Bool
    let onScrubbingChanged: ((Bool) -> Void)?
    @AppStorage("playerMuted") private var storedPlayerMuted = false
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var loadedAssetDuration: Double = 0
    @State private var buffered: Double = 0
    @State private var isScrubbing = false
    @State private var showControls = true
    @State private var showSpeedMenu = false
    @State private var playbackRate: Float = 1
    @State private var timeObserver: Any?
    @State private var timeObserverPlayer: AVPlayer?
    @State private var seekGeneration = 0
    @State private var playbackStatusObserver: NSKeyValueObservation?
    @State private var currentItemObserver: NSKeyValueObservation?
    @State private var hideTask: Task<Void, Never>?
    @State private var momentGraphLikeSecond: Int?
    @State private var momentGraphLikeBoost: CGFloat = 0
    @State private var displayedLikedSeconds: Set<Int>
    @State private var displayedHeatmapValues: [CGFloat]
    @State private var displayedHeatmapMaxValue: CGFloat
    @State private var clipMode = false
    @State private var showClipFinalizeSheet = false
    @State private var clipMarkIn: Double = 0
    @State private var clipMarkOut: Double = 0
    @State private var activeClipHandle: ClipHandle?
    @State private var isClipPreviewing = false
    @State private var clipCaption = ""
    @State private var clipIsSpoiler = false
    @State private var clipSaving = false
    @State private var clipError: String?

    private let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var timelineChromeHeight: CGFloat {
        clipMode ? 60 : 34
    }

    private var showsFullscreenRelatedStrip: Bool {
        isFullscreenPresentation && showControls && !relatedItems.isEmpty
    }

    private var controlsBottomPadding: CGFloat {
        if clipMode {
            return timelineChromeHeight + 8
        }
        return showsFullscreenRelatedStrip ? 124 : 18
    }

    private var adBreakCountdownText: String? {
        let nextBreak = adBreaks
            .filter { !watchedAdBreakIds.contains($0.id) }
            .filter { $0.timeOffsetSec > currentTime }
            .sorted { $0.timeOffsetSec < $1.timeOffsetSec }
            .first
        guard let nextBreak else { return nil }
        let remaining = nextBreak.timeOffsetSec - currentTime
        guard remaining > 0, remaining <= 5 else { return nil }
        let seconds = max(1, Int(ceil(remaining)))
        return "Ads start in \(seconds) \(seconds == 1 ? "second" : "seconds")"
    }

    init(
        player: AVPlayer,
        heatmapBuckets: [Int] = [],
        likedSeconds: [Int] = [],
        isAuthenticated: Bool = false,
        onLikeMoment: ((Int) -> Void)? = nil,
        showSpoilerToggle: Bool = false,
        onClipRequest: ClipRequestHandler? = nil,
        activeClipRange: Binding<ClipPlaybackRange?> = .constant(nil),
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onFullscreen: @escaping () -> Void,
        isFullscreenPresentation: Bool = false,
        relatedItems: [PlayerRelatedItem] = [],
        onSelectRelated: ((PlayerRelatedItem) -> Void)? = nil,
        adBreaks: [AdBreak] = [],
        watchedAdBreakIds: Set<String> = [],
        onAdBreakRequested: ((AdBreak, Double?) -> Void)? = nil,
        knownDuration: Double? = nil,
        controlsInitiallyVisible: Bool = true,
        onScrubbingChanged: ((Bool) -> Void)? = nil,
        @ViewBuilder markers: () -> MarkerOverlay
    ) {
        self.player = player
        self.heatmapBuckets = heatmapBuckets
        self.likedSeconds = likedSeconds
        self._displayedLikedSeconds = State(initialValue: Set(likedSeconds))
        self._displayedHeatmapValues = State(initialValue: heatmapBuckets.map { CGFloat($0) })
        self._displayedHeatmapMaxValue = State(initialValue: max(1, CGFloat(heatmapBuckets.max() ?? 0)))
        self.isAuthenticated = isAuthenticated
        self.onLikeMoment = onLikeMoment
        self.showSpoilerToggle = showSpoilerToggle
        self.onClipRequest = onClipRequest
        self._activeClipRange = activeClipRange
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onBack = onBack
        self.onFullscreen = onFullscreen
        self.isFullscreenPresentation = isFullscreenPresentation
        self.relatedItems = relatedItems
        self.onSelectRelated = onSelectRelated
        self.adBreaks = adBreaks
        self.watchedAdBreakIds = watchedAdBreakIds
        self.onAdBreakRequested = onAdBreakRequested
        self.knownDuration = knownDuration
        self.controlsInitiallyVisible = controlsInitiallyVisible
        self.onScrubbingChanged = onScrubbingChanged
        self._showControls = State(initialValue: controlsInitiallyVisible)
        self.markers = markers()
    }

    var body: some View {
        ZStack {
            WatchPlayerSurface(player: player)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { toggleControlsOrPlayback() }

            if showControls {
                controlsLayer
                    .transition(.opacity)
                    .zIndex(2)
            }

            if let adBreakCountdownText {
                Text(adBreakCountdownText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.75), in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.15), lineWidth: 1) }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .zIndex(2.5)
            }

            if let activeClipRange, !clipMode {
                activeClipPlaybackBadge(activeClipRange)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .zIndex(2.6)
            }

            bottomEdgeTimeline
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(30)

            markers
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(3)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .onAppear { attachObservers() }
        .onDisappear { detachObservers() }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard timeObserver == nil else { return }
            updateTimelineState()
        }
        .onChange(of: isMuted) { _, muted in
            player.isMuted = muted
            storedPlayerMuted = muted
        }
        .onChange(of: playbackRate) { _, rate in
            if isPlaying { player.rate = rate }
        }
        .onChange(of: likedSeconds) { _, newValue in
            replaceDisplayedLikedSeconds(newValue)
        }
        .onChange(of: heatmapBuckets) { _, newValue in
            replaceDisplayedHeatmap(newValue)
        }
        .sheet(isPresented: $showClipFinalizeSheet, onDismiss: closeClipSheet) {
            ClipToolSheet(
                markIn: clipMarkIn,
                markOut: clipMarkOut,
                caption: $clipCaption,
                isSpoiler: $clipIsSpoiler,
                isSaving: clipSaving,
                errorMessage: clipError,
                showSpoilerToggle: showSpoilerToggle,
                onPreview: previewSelectedClip,
                onSave: { Task { await saveClip() } },
                onCancel: cancelClipMode
            )
            .presentationDetents([.height(330), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(hex: "#101014"))
        }
    }

    private var controlsLayer: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.68), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if !isPlaying && !clipMode {
                Button {
                    togglePlayback()
                } label: {
                    MediaverseIcon(name: "play", fallbackSystemName: "play")
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play")
                .accessibilityHint("Plays the video")
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let onBack {
                        Button {
                            onBack()
                        } label: {
                            MediaverseIcon(name: "chevron-down", fallbackSystemName: "chevron.down")
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.black.opacity(0.36))
                                .clipShape(Circle())
                                .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }

                    if let onPrevious {
                        chromeButton(iconName: "skip-back", fallbackSystemName: "backward.end") {
                            onPrevious()
                            scheduleHide()
                        }
                    }

                    if let onNext {
                        chromeButton(iconName: "skip-forward", fallbackSystemName: "forward.end") {
                            onNext()
                            scheduleHide()
                        }
                    }

                    Spacer()
                    chromeButton(iconName: isMuted ? "mute" : "volume", fallbackSystemName: isMuted ? "speaker.slash" : "speaker.wave.2") {
                        isMuted.toggle()
                        scheduleHide()
                    }

                    ZStack(alignment: .topTrailing) {
                        chromeButton(iconName: "settings", fallbackSystemName: "gearshape", active: showSpeedMenu || playbackRate != 1) {
                            withAnimation(.easeOut(duration: 0.16)) { showSpeedMenu.toggle() }
                            scheduleHide()
                        }
                        if showSpeedMenu {
                            speedMenu
                                .offset(y: 42)
                        }
                    }

                    chromeButton(
                        iconName: isFullscreenPresentation ? "fullscreen-exit" : "fullscreen",
                        fallbackSystemName: isFullscreenPresentation ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    ) {
                        onFullscreen()
                    }

                }
                .padding(.top, 10)
                .padding(.horizontal, onBack == nil ? 10 : 16)

                Spacer()

                VStack(spacing: hasHeatmap ? 6 : 8) {
                    if hasMomentGraph {
                        topMomentsGraph
                    }

                    if clipMode {
                        clipSelectionActions
                    }

                    transportActionRow
                }
                .padding(.horizontal, 12)
                .padding(.bottom, controlsBottomPadding)
            }
        }
        .onAppear { scheduleHide() }
    }

    private var bottomEdgeTimeline: some View {
        VStack(spacing: showsFullscreenRelatedStrip ? 8 : 0) {
            heatmapProgressBar
                .frame(height: timelineChromeHeight, alignment: .bottom)

            if showsFullscreenRelatedStrip {
                relatedStrip
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, isFullscreenPresentation ? 14 : 0)
    }

    private var topMomentsGraph: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                MediaverseIcon(name: "star", fallbackSystemName: "star")
                    .frame(width: 7, height: 7)
                Text("Top Moments")
                    .font(.system(size: 9, weight: .bold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(C.watch.opacity(0.70))

            Canvas { ctx, size in
                drawHeatmapWave(ctx: ctx, size: size)
            }
            .frame(height: 22)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transportActionRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    togglePlayback()
                } label: {
                    MediaverseIcon(name: isPlaying ? "pause" : "play", fallbackSystemName: isPlaying ? "pause" : "play")
                        .frame(width: 17, height: 17)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityHint(isPlaying ? "Pauses the video" : "Plays the video")

                Text("\(formatTime(currentTime)) / \(formatTime(resolvedDuration()))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.42), in: Capsule())

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                momentButton
                clipButton

                if playbackRate != 1 {
                    Text(speedLabel(playbackRate))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(C.watch)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.42))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var relatedStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Up next")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(relatedItems.prefix(8)) { item in
                        Button {
                            onSelectRelated?(item)
                            scheduleHide()
                        } label: {
                            relatedCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relatedCard(_ item: PlayerRelatedItem) -> some View {
        HStack(spacing: 8) {
            CachedRemoteImage(
                url: C.mediaURL(item.thumbnailUrl),
                targetSize: CGSize(width: 86, height: 48),
                loadDelayNanoseconds: 40_000_000
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 86, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .center) {
                Circle()
                    .fill(.black.opacity(0.42))
                    .frame(width: 22, height: 22)
                    .overlay {
                        MediaverseIcon(name: "play", fallbackSystemName: "play")
                            .frame(width: 8, height: 8)
                            .foregroundStyle(.white)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: 118, alignment: .leading)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                        .frame(width: 118, alignment: .leading)
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1) }
    }

    private var heatmapProgressBar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let timelineDuration = resolvedDuration()
            let progress = min(max(timelineDuration > 0 ? currentTime / timelineDuration : 0, 0), 1)
            let bufferProgress = min(max(timelineDuration > 0 ? buffered / timelineDuration : 0, 0), 1)
            let playedWidth = width * CGFloat(progress)
            let bufferedWidth = width * CGFloat(bufferProgress)
            let trackHeight: CGFloat = clipMode || isScrubbing ? 5 : 4
            let showsThumb = showControls || isScrubbing
            let thumbSize: CGFloat = 16
            let thumbX = min(max(playedWidth - (thumbSize / 2), 0), max(width - thumbSize, 0))

            ZStack(alignment: .bottomLeading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.18))
                        .frame(height: trackHeight)
                    Rectangle().fill(.white.opacity(0.30))
                        .frame(width: bufferedWidth, height: trackHeight)
                    Rectangle().fill(C.watch)
                        .frame(width: playedWidth, height: trackHeight)

                    if timelineDuration > 0 {
                        ForEach(adBreaks) { adBreak in
                            let markerX = width * CGFloat(min(max(adBreak.timeOffsetSec / timelineDuration, 0), 1))
                            adBreakMarker(isWatched: watchedAdBreakIds.contains(adBreak.id))
                                .offset(x: min(width - 6, max(0, markerX - 3)), y: -9)
                        }
                    }

                    if showsThumb {
                        Circle()
                            .fill(C.watch)
                            .frame(width: thumbSize, height: thumbSize)
                            .overlay {
                                Circle()
                                    .stroke(.black.opacity(0.28), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                            .offset(x: thumbX)
                    }

                    if let range = displayedClipRange, timelineDuration > 0 {
                        let start = min(range.markIn, range.markOut)
                        let end = max(range.markIn, range.markOut)
                        let startX = width * CGFloat(start / timelineDuration)
                        let endX = width * CGFloat(end / timelineDuration)
                        RoundedRectangle(cornerRadius: 2)
                            .fill((clipMode ? C.watch : Color.white).opacity(clipMode ? 0.28 : 0.22))
                            .frame(width: max(2, endX - startX), height: clipMode ? 12 : 9)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(C.watch.opacity(clipMode ? 0.70 : 0.90), lineWidth: 1)
                            }
                            .offset(x: startX, y: -5)
                        if clipMode {
                            clipHandleView(label: "In")
                                .offset(x: max(0, startX - 18), y: -26)
                            clipHandleView(label: "Out")
                                .offset(x: min(width - 36, max(0, endX - 18)), y: -26)
                        } else {
                            clipPlaybackMarker(label: "In")
                                .offset(x: max(0, startX - 11), y: -17)
                            clipPlaybackMarker(label: "Out")
                                .offset(x: min(width - 22, max(0, endX - 11)), y: -17)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: trackHeight)
            }
            .frame(width: width, height: geo.size.height, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard timelineDuration > 0 else { return }
                        hideTask?.cancel()
                        if !isScrubbing {
                            onScrubbingChanged?(true)
                        }
                        isScrubbing = true
                        let pct = min(max(0, value.location.x / width), 1)
                        if clipMode {
                            updateClipHandle(to: timelineDuration * pct, phaseStarted: activeClipHandle == nil)
                        } else {
                            let targetSeconds = timelineDuration * pct
                            clearActiveClipRangeIfNeeded(for: targetSeconds)
                            currentTime = targetSeconds
                        }
                    }
                    .onEnded { value in
                        guard timelineDuration > 0 else {
                            isScrubbing = false
                            onScrubbingChanged?(false)
                            return
                        }
                        let pct = min(max(0, value.location.x / width), 1)
                        if clipMode {
                            updateClipHandle(to: timelineDuration * pct, phaseStarted: false)
                            activeClipHandle = nil
                        } else {
                            seek(to: timelineDuration * pct)
                        }
                        isScrubbing = false
                        onScrubbingChanged?(false)
                        scheduleHide()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(clipMode ? "Clip range scrubber" : "Playback position")
            .accessibilityValue("\(formatTime(currentTime)) of \(formatTime(timelineDuration))")
            .accessibilityAdjustableAction { direction in
                guard timelineDuration > 0, !clipMode else { return }
                switch direction {
                case .increment:
                    seek(to: min(timelineDuration, currentTime + 10))
                case .decrement:
                    seek(to: max(0, currentTime - 10))
                default:
                    break
                }
                scheduleHide()
            }
        }
        .frame(height: timelineChromeHeight)
    }

    private func adBreakMarker(isWatched: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(isWatched ? Color.white.opacity(0.32) : Color(hex: "#FBBF24"))
            .frame(width: 6, height: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(.black.opacity(0.45), lineWidth: 1)
            }
            .accessibilityLabel(isWatched ? "Watched ad break" : "Ad break")
    }

    private func unwatchedAdBreakCrossed(from start: Double, to target: Double) -> AdBreak? {
        guard target > start else { return nil }
        return adBreaks
            .filter { !watchedAdBreakIds.contains($0.id) }
            .filter { $0.timeOffsetSec > start + 0.25 && $0.timeOffsetSec <= target + 0.25 }
            .sorted { $0.timeOffsetSec < $1.timeOffsetSec }
            .first
    }

    private func clipHandleView(label: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 16)
                .background(C.watch)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
            Rectangle()
                .fill(C.watch)
                .frame(width: 4, height: 14)
            Circle()
                .fill(C.watch)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .stroke(.black.opacity(0.45), lineWidth: 1)
                }
        }
        .frame(width: 48, height: 58)
        .contentShape(Rectangle())
    }

    private func clipPlaybackMarker(label: String) -> some View {
        Text(label)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(.black)
            .frame(width: 22, height: 12)
            .background(C.watch, in: Capsule())
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }

    private func activeClipPlaybackBadge(_ range: ClipPlaybackRange) -> some View {
        HStack(spacing: 5) {
            MediaverseIcon(name: "cut", fallbackSystemName: "scissors")
                .frame(width: 10, height: 10)
            Text("Clip \(formatTime(range.markIn)) - \(formatTime(range.markOut))")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(C.watch, in: Capsule())
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    @ViewBuilder
    private var momentButton: some View {
        if isAuthenticated, onLikeMoment != nil {
            let sec = max(0, Int(currentTime.rounded(.down)))
            let isLiked = displayedLikedSeconds.contains(sec)
            Button {
                likeCurrentMoment()
            } label: {
                HStack(spacing: 5) {
                    MediaverseIcon(name: isLiked ? "heart-filled" : "heart", fallbackSystemName: "heart")
                        .frame(width: 12, height: 12)
                    Text("Moment")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(isLiked ? C.watch : .white.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(isLiked ? C.watch.opacity(0.18) : .white.opacity(0.10))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(isLiked ? C.watch.opacity(0.36) : .white.opacity(0.12), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var clipSelectionActions: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Select clip range")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(formatTime(clipMarkIn)) - \(formatTime(clipMarkOut))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button(action: cancelClipMode) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(height: 28)
                    .padding(.horizontal, 10)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: confirmClipSelection) {
                Text("Continue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(height: 28)
                    .padding(.horizontal, 12)
                    .background(Int(clipMarkOut) > Int(clipMarkIn) ? C.watch : C.watch.opacity(0.38))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(Int(clipMarkOut) <= Int(clipMarkIn))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.12), lineWidth: 1) }
    }

    @ViewBuilder
    private var clipButton: some View {
        if isAuthenticated, onClipRequest != nil {
            Button {
                toggleClipMode()
            } label: {
                MediaverseIcon(name: "cut", fallbackSystemName: "scissors")
                    .frame(width: 13, height: 13)
                    .foregroundStyle(clipMode ? C.watch : .white.opacity(0.78))
                    .frame(width: 30, height: 28)
                    .background(clipMode ? C.watch.opacity(0.18) : .white.opacity(0.10))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(clipMode ? C.watch.opacity(0.36) : .white.opacity(0.12), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var clipEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Create clip")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(formatTime(clipMarkIn)) - \(formatTime(clipMarkOut))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                clipTimeButton("Set in") { setClipInToCurrentTime() }
                clipTimeButton("Set out") { setClipOutToCurrentTime() }
                if showSpoilerToggle {
                    Button {
                        clipIsSpoiler.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            MediaverseIcon(name: clipIsSpoiler ? "eye-off" : "eye", fallbackSystemName: clipIsSpoiler ? "eye.slash" : "eye")
                                .frame(width: 12, height: 12)
                            Text("Spoiler")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(clipIsSpoiler ? C.watch : .white.opacity(0.62))
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .background(.white.opacity(0.08))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                Button {
                    Task { await saveClip() }
                } label: {
                    Text(clipSaving ? "Saving..." : "Post clip")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(height: 26)
                        .padding(.horizontal, 11)
                        .background(C.watch)
                        .clipShape(Capsule())
                }
                .disabled(clipSaving || Int(clipMarkOut) <= Int(clipMarkIn))
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { clipMode = false }
                    clipError = nil
                    scheduleHide()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(height: 26)
                        .padding(.horizontal, 10)
                        .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }

            TextField("What are you reacting to?", text: $clipCaption)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textInputAutocapitalization(.sentences)

            if let clipError {
                Text(clipError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1) }
    }

    private func clipTimeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var speedMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Playback speed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(speeds, id: \.self) { speed in
                Button {
                    playbackRate = speed
                    if isPlaying { player.rate = speed }
                    withAnimation(.easeOut(duration: 0.16)) { showSpeedMenu = false }
                    scheduleHide()
                } label: {
                    HStack(spacing: 8) {
                        Text(speedLabel(speed))
                            .font(.system(size: 12, weight: speed == playbackRate ? .bold : .medium))
                            .foregroundStyle(speed == playbackRate ? C.watch : .white.opacity(0.82))
                        Spacer(minLength: 12)
                        if speed == playbackRate {
                            MediaverseIcon(name: "check", fallbackSystemName: "checkmark")
                                .frame(width: 10, height: 10)
                                .foregroundStyle(C.watch)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 154)
        .padding(.bottom, 8)
        .background(.black.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .zIndex(20)
    }

    private func chromeButton(iconName: String, fallbackSystemName: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                .frame(width: 16, height: 16)
                .foregroundStyle(active ? C.watch : .white.opacity(0.88))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chromeButtonAccessibilityLabel(iconName: iconName, fallbackSystemName: fallbackSystemName))
    }

    private func chromeButtonAccessibilityLabel(iconName: String, fallbackSystemName: String) -> String {
        switch iconName {
        case "skip-back": return "Previous"
        case "skip-forward": return "Next"
        case "mute": return "Unmute"
        case "volume": return "Mute"
        case "settings": return "Playback speed"
        case "fullscreen": return "Enter fullscreen"
        case "fullscreen-exit": return "Exit fullscreen"
        default: return fallbackSystemName
        }
    }

    private var hasHeatmap: Bool {
        duration > 0 && displayedHeatmapValues.count >= 2 && displayedHeatmapMaxValue > 0
    }

    private var hasMomentGraph: Bool {
        duration > 0 && (hasHeatmap || !displayedLikedSeconds.isEmpty)
    }

    private var playerHasActivePlaybackIntent: Bool {
        player.timeControlStatus != .paused || player.rate > 0
    }

    private var displayedClipRange: ClipPlaybackRange? {
        if clipMode {
            return ClipPlaybackRange(markIn: clipMarkIn, markOut: clipMarkOut)
        }
        return activeClipRange
    }

    private func setCurrentTimeIfNeeded(_ value: Double, tolerance: Double = 0.04) {
        guard abs(currentTime - value) > tolerance else { return }
        currentTime = value
    }

    private func setDurationIfNeeded(_ value: Double, tolerance: Double = 0.05) {
        guard abs(duration - value) > tolerance else { return }
        duration = value
    }

    private func setBufferedIfNeeded(_ value: Double, tolerance: Double = 0.15) {
        guard abs(buffered - value) > tolerance else { return }
        buffered = value
    }

    private func updateTimelineState() {
        if !isScrubbing, let playerTime = player.currentTime().seconds.validTime {
            setCurrentTimeIfNeeded(playerTime)
        }
        setDurationIfNeeded(resolvedDuration())
        setBufferedIfNeeded(bufferedEnd(from: player.currentItem))
        syncPlaybackState()
    }

    private func resolvedDuration() -> Double {
        guard let item = player.currentItem else { return 0 }

        let directDuration = item.duration.seconds.validTime
        let serverDuration = knownDuration?.validTime
        let assetDuration = loadedAssetDuration.validTime
        let seekableEnd = item.seekableTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .compactMap(\.validTime)
            .max()
        let loadedEnd = item.loadedTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .compactMap(\.validTime)
            .max()

        return [directDuration, serverDuration, assetDuration, seekableEnd, loadedEnd, duration]
            .compactMap { $0 }
            .filter { $0 > 0 }
            .max() ?? 0
    }

    private func loadAssetDurationIfNeeded() async {
        guard knownDuration?.validTime == nil,
              loadedAssetDuration.validTime == nil,
              let item = player.currentItem else { return }

        let assetDuration = try? await item.asset.load(.duration).seconds
        guard let assetDuration = assetDuration?.validTime else { return }

        await MainActor.run {
            guard player.currentItem === item else { return }
            if abs(loadedAssetDuration - assetDuration) > 0.05 {
                loadedAssetDuration = assetDuration
            }
            setDurationIfNeeded(resolvedDuration())
        }
    }

    private func attachObservers() {
        detachObservers()
        player.isMuted = storedPlayerMuted
        isMuted = storedPlayerMuted
        updateTimelineState()
        Task { await loadAssetDurationIfNeeded() }

        playbackStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                syncPlaybackState()
            }
        }

        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                loadedAssetDuration = 0
                updateTimelineState()
                Task { await loadAssetDurationIfNeeded() }
            }
        }

        timeObserverPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { _ in
            updateTimelineState()
        }
    }

    private func detachObservers() {
        hideTask?.cancel()
        playbackStatusObserver?.invalidate()
        playbackStatusObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        if let timeObserver {
            timeObserverPlayer?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            timeObserverPlayer = nil
        }
    }

    private func syncPlaybackState() {
        if clipMode, isClipPreviewing, currentTime >= clipMarkOut - 0.05 {
            player.pause()
            player.seek(to: CMTime(seconds: clipMarkOut, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            isClipPreviewing = false
        }

        if let activeClipRange, !isScrubbing, playerHasActivePlaybackIntent, currentTime >= activeClipRange.markOut - 0.05 {
            player.pause()
            player.seek(to: CMTime(seconds: activeClipRange.markOut, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            self.activeClipRange = nil
        }

        let hasPlaybackIntent = playerHasActivePlaybackIntent
        if isPlaying != hasPlaybackIntent {
            isPlaying = hasPlaybackIntent
        }
        if !hasPlaybackIntent {
            if hideTask != nil {
                hideTask?.cancel()
                hideTask = nil
            }
            if !showControls {
                withAnimation(.easeOut(duration: 0.16)) { showControls = true }
            }
        }
    }

    private func toggleControlsOrPlayback() {
        hideTask?.cancel()
        syncPlaybackState()

        if showControls, !clipMode, !isScrubbing, !showSpeedMenu {
            withAnimation(.easeOut(duration: 0.16)) { showControls = false }
            return
        }

        withAnimation(.easeOut(duration: 0.18)) { showControls = true }
        if isPlaying {
            scheduleHide()
        }
    }

    private func togglePlayback() {
        if playerHasActivePlaybackIntent {
            player.pause()
            isPlaying = false
            isClipPreviewing = false
            withAnimation(.easeOut(duration: 0.18)) { showControls = true }
            hideTask?.cancel()
        } else {
            if let activeClipRange,
               currentTime < activeClipRange.markIn || currentTime >= activeClipRange.markOut {
                self.activeClipRange = nil
            }
            if playbackRate == 1 {
                player.play()
            } else {
                player.rate = playbackRate
            }
            isPlaying = true
            scheduleHide()
        }
    }

    private func clearActiveClipRangeIfNeeded(for seconds: Double) {
        guard let activeClipRange else { return }
        if seconds < activeClipRange.markIn || seconds >= activeClipRange.markOut {
            self.activeClipRange = nil
        }
    }

    private func seek(to seconds: Double, exact: Bool = false) {
        let timelineDuration = resolvedDuration()
        setDurationIfNeeded(timelineDuration)
        let clampedSeconds = min(max(seconds, 0), max(timelineDuration, 0))
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)

        clearActiveClipRangeIfNeeded(for: clampedSeconds)

        currentTime = clampedSeconds
        seekGeneration += 1
        let generation = seekGeneration
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            Task { @MainActor in
                guard finished, generation == seekGeneration else { return }
                if playbackRate == 1 {
                    player.playImmediately(atRate: 1)
                } else {
                    player.rate = playbackRate
                }
                isPlaying = true
                scheduleHide()
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying, !clipMode else { return }
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !showSpeedMenu else { return }
            withAnimation(.easeOut(duration: 0.22)) { showControls = false }
        }
    }

    private func toggleClipMode() {
        if clipMode {
            cancelClipMode()
            return
        }

        startClipSelection()
    }

    private func startClipSelection() {
        hideTask?.cancel()
        activeClipRange = nil
        player.pause()
        isPlaying = false
        isClipPreviewing = false
        let start = max(0, currentTime - 5)
        let end = min(max(duration, currentTime + 1), currentTime + 10)
        clipMarkIn = floor(start)
        clipMarkOut = floor(max(start + 1, end))
        clipCaption = ""
        clipError = nil
        withAnimation(.easeOut(duration: 0.18)) {
            showControls = true
            clipMode = true
        }
    }

    private func confirmClipSelection() {
        guard Int(clipMarkOut) > Int(clipMarkIn) else {
            clipError = "Clip out must be after clip in."
            return
        }
        player.pause()
        isPlaying = false
        isClipPreviewing = false
        clipError = nil
        showControls = true
        showClipFinalizeSheet = true
    }

    private func cancelClipMode() {
        showClipFinalizeSheet = false
        withAnimation(.easeOut(duration: 0.18)) { clipMode = false }
        isClipPreviewing = false
        clipError = nil
        scheduleHide()
    }

    private func closeClipSheet() {
        showClipFinalizeSheet = false
        activeClipHandle = nil
        isClipPreviewing = false
        scheduleHide()
    }

    private func setClipInToCurrentTime() {
        clipMarkIn = min(floor(currentTime), max(0, clipMarkOut - 1))
    }

    private func setClipOutToCurrentTime() {
        clipMarkOut = max(floor(currentTime), clipMarkIn + 1)
    }

    private func previewSelectedClip() {
        guard duration > 0, clipMarkOut > clipMarkIn else { return }
        hideTask?.cancel()
        isClipPreviewing = true
        let target = CMTime(seconds: clipMarkIn, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                if playbackRate == 1 {
                    player.play()
                } else {
                    player.rate = playbackRate
                }
                isPlaying = true
                showControls = true
            }
        }
    }

    private func updateClipHandle(to value: Double, phaseStarted: Bool) {
        let clamped = min(max(value, 0), duration)
        if activeClipHandle == nil || phaseStarted {
            let inDistance = abs(clamped - clipMarkIn)
            let outDistance = abs(clamped - clipMarkOut)
            activeClipHandle = inDistance <= outDistance ? .markIn : .markOut
        }

        switch activeClipHandle {
        case .markIn:
            clipMarkIn = min(floor(clamped), max(0, clipMarkOut - 1))
        case .markOut:
            clipMarkOut = max(floor(clamped), clipMarkIn + 1)
        case nil:
            break
        }
    }

    private func saveClip() async {
        guard let onClipRequest, !clipSaving else { return }
        let markIn = Int(floor(clipMarkIn))
        let markOut = Int(floor(clipMarkOut))
        guard markOut > markIn else {
            clipError = "Clip out must be after clip in."
            return
        }

        clipSaving = true
        clipError = nil
        do {
            let thumbnailData = await makeClipThumbnailData(at: markIn)
            try await onClipRequest(markIn, markOut, clipCaption.trimmingCharacters(in: .whitespacesAndNewlines), clipIsSpoiler, thumbnailData)
            await MainActor.run {
                clipSaving = false
                showClipFinalizeSheet = false
                clipMode = false
                isClipPreviewing = false
                clipCaption = ""
                clipIsSpoiler = false
                scheduleHide()
            }
        } catch {
            await MainActor.run {
                clipSaving = false
                clipError = error.localizedDescription
            }
        }
    }

    private func makeClipThumbnailData(at seconds: Int) async -> Data? {
        guard let asset = player.currentItem?.asset else { return nil }
        return await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            let time = CMTime(seconds: Double(seconds), preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
        }.value
    }

    private func likeCurrentMoment() {
        guard let onLikeMoment else { return }
        let sec = max(0, Int(currentTime.rounded(.down)))
        if displayedLikedSeconds.contains(sec) {
            displayedLikedSeconds.remove(sec)
        } else {
            displayedLikedSeconds.insert(sec)
        }
        onLikeMoment(sec)

        momentGraphLikeSecond = sec
        momentGraphLikeBoost = 0
        withAnimation(.linear(duration: 0.18)) {
            momentGraphLikeBoost = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.linear(duration: 0.16)) {
                momentGraphLikeBoost = 0
            }
            momentGraphLikeSecond = nil
        }
        scheduleHide()
    }

    private func replaceDisplayedLikedSeconds(_ seconds: [Int]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedLikedSeconds = Set(seconds)
        }
    }

    private func replaceDisplayedHeatmap(_ buckets: [Int]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedHeatmapValues = buckets.map { CGFloat($0) }
            displayedHeatmapMaxValue = max(1, CGFloat(buckets.max() ?? 0))
        }
    }

    private func momentGraphValues() -> [CGFloat] {
        let bucketSize = 5.0
        let targetCount = max(2, Int(ceil(duration / bucketSize)) + 1)
        let count = hasHeatmap ? max(2, min(targetCount, displayedHeatmapValues.count)) : targetCount
        guard count >= 2 else { return [] }

        var values = Array(repeating: CGFloat(0.08), count: count)
        if hasHeatmap {
            for idx in 0..<count {
                values[idx] = max(0.08, displayedHeatmapValues[idx])
            }
        }

        let likedBoost = max(1.5, displayedHeatmapMaxValue * 0.32)
        for second in displayedLikedSeconds {
            let idx = min(count - 1, max(0, Int(round(Double(second) / bucketSize))))
            values[idx] += likedBoost
            if idx > 0 { values[idx - 1] += likedBoost * 0.45 }
            if idx < count - 1 { values[idx + 1] += likedBoost * 0.45 }
        }

        if let momentGraphLikeSecond, momentGraphLikeBoost > 0 {
            let idx = min(count - 1, max(0, Int(round(Double(momentGraphLikeSecond) / bucketSize))))
            let animatedBoost = likedBoost * (0.5 + momentGraphLikeBoost)
            values[idx] += animatedBoost
            if idx > 0 { values[idx - 1] += animatedBoost * 0.35 }
            if idx < count - 1 { values[idx + 1] += animatedBoost * 0.35 }
        }

        return values
    }

    private func drawHeatmapWave(ctx: GraphicsContext, size: CGSize) {
        guard hasMomentGraph else { return }

        let width = size.width
        let height = size.height
        let values = momentGraphValues()
        guard values.count >= 2 else { return }
        let maxValue = max(1, values.max() ?? 1)

        let points: [CGPoint] = values.indices.map { idx in
            let value = values[idx]
            let x = CGFloat(idx) / CGFloat(max(1, values.count - 1)) * width
            let y = height - max(2, (value / maxValue) * height * 0.90)
            return CGPoint(x: x, y: y)
        }

        var stroke = Path()
        stroke.move(to: points[0])
        for idx in 0 ..< points.count - 1 {
            let current = points[idx]
            let next = points[idx + 1]
            let midX = (current.x + next.x) / 2
            stroke.addCurve(
                to: next,
                control1: CGPoint(x: midX, y: current.y),
                control2: CGPoint(x: midX, y: next.y)
            )
        }

        var fill = stroke
        fill.addLine(to: CGPoint(x: width, y: height))
        fill.addLine(to: CGPoint(x: 0, y: height))
        fill.closeSubpath()

        ctx.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [C.watch.opacity(0.25), C.watch.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: height)
            )
        )
        ctx.stroke(
            stroke,
            with: .color(C.watch.opacity(0.38 + (0.18 * momentGraphLikeBoost))),
            style: StrokeStyle(lineWidth: 1.4 + (0.4 * momentGraphLikeBoost), lineCap: .round)
        )
    }

    private func bufferedEnd(from item: AVPlayerItem?) -> Double {
        guard let range = item?.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
        return end.isFinite ? end : 0
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1 ? "Normal" : "\(String(format: "%g", speed))x"
    }
}

private struct ClipToolSheet: View {
    let markIn: Double
    let markOut: Double
    @Binding var caption: String
    @Binding var isSpoiler: Bool

    let isSaving: Bool
    let errorMessage: String?
    let showSpoilerToggle: Bool
    let onPreview: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    private var clipDuration: Double { max(0, markOut - markIn) }
    private var canSave: Bool { !isSaving && Int(markOut) > Int(markIn) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review the range you selected on the player timeline.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))

                    HStack(spacing: 10) {
                        markBadge(title: "In", value: markIn)
                        markBadge(title: "Out", value: markOut)
                        markBadge(title: "Length", value: clipDuration)
                    }
                }

                sheetButton(title: "Preview selected range", icon: "play", action: onPreview)

                TextField("What are you reacting to?", text: $caption, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .textInputAutocapitalization(.sentences)

                if showSpoilerToggle {
                    Toggle(isOn: $isSpoiler) {
                        HStack(spacing: 8) {
                            MediaverseIcon(name: isSpoiler ? "eye-off" : "eye", fallbackSystemName: isSpoiler ? "eye.slash" : "eye")
                                .frame(width: 16, height: 16)
                            Text("Mark as spoiler")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(isSpoiler ? C.watch : .white.opacity(0.78))
                    }
                    .toggleStyle(.switch)
                    .tint(C.watch)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(0.95))
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    Button(action: onSave) {
                        Text(isSaving ? "Posting..." : "Post clip")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(canSave ? C.watch : C.watch.opacity(0.38))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(Color(hex: "#101014"))
            .navigationTitle("Create clip")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func markBadge(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.46))
                .textCase(.uppercase)
            Text(formatTime(value))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(title == "Length" ? .white : C.watch)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1) }
    }

    private func sheetButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.10), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private enum ClipHandle {
    case markIn
    case markOut
}

struct WatchPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        guard uiView.player !== player else { return }
        uiView.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

        var player: AVPlayer? {
            get { playerLayer?.player }
            set {
                guard playerLayer?.player !== newValue else { return }
                playerLayer?.player = newValue
                playerLayer?.videoGravity = .resizeAspect
            }
        }
    }
}

struct MiniWatchPlayer: View {
    let player: AVPlayer
    let title: String
    let onExpand: () -> Void
    let onClose: () -> Void
    let onPlaybackEnded: (() -> Void)?

    @State private var isPlaying = false
    @State private var playbackStatusObserver: NSKeyValueObservation?
    @State private var playbackEndObserver: NSObjectProtocol?

    private var playerHasActivePlaybackIntent: Bool {
        player.timeControlStatus != .paused || player.rate > 0
    }

    var body: some View {
        ZStack {
            WatchPlayerSurface(player: player)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

            LinearGradient(
                colors: [.black.opacity(0.18), .clear, .black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            Button(action: togglePlayback) {
                MediaverseIcon(name: isPlaying ? "pause" : "play", fallbackSystemName: isPlaying ? "pause" : "play")
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.50))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)

            Button(action: onClose) {
                MediaverseIcon(name: "close", fallbackSystemName: "xmark")
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close mini player")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(6)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.42), radius: 12, y: 4)
        .onAppear { attachPlaybackObservers() }
        .onDisappear { detachPlaybackObservers() }
    }

    private func togglePlayback() {
        if playerHasActivePlaybackIntent {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func attachPlaybackObservers() {
        detachPlaybackObservers()
        syncPlaybackState()
        playbackStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                syncPlaybackState()
            }
        }
        if let onPlaybackEnded, let item = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    onPlaybackEnded()
                }
            }
        }
    }

    private func detachPlaybackObservers() {
        playbackStatusObserver?.invalidate()
        playbackStatusObserver = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
    }

    private func syncPlaybackState() {
        let hasPlaybackIntent = playerHasActivePlaybackIntent
        guard isPlaying != hasPlaybackIntent else { return }
        isPlaying = hasPlaybackIntent
    }
}

extension Double {
    var validTime: Double? {
        isFinite && !isNaN && self >= 0 ? self : nil
    }
}
