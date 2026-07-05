import SwiftUI
import AVKit

struct WatchPlayerChrome<MarkerOverlay: View>: View {
    let player: AVPlayer
    let heatmapBuckets: [Int]
    let likedSeconds: [Int]
    let isAuthenticated: Bool
    let onLikeMoment: ((Int) -> Void)?
    let showSpoilerToggle: Bool
    let onClipRequest: ((Int, Int, String, Bool) async throws -> Void)?
    var markers: MarkerOverlay
    var onBack: (() -> Void)?
    var onFullscreen: () -> Void

    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var buffered: Double = 0
    @State private var showControls = true
    @State private var showSpeedMenu = false
    @State private var playbackRate: Float = 1
    @State private var timeObserver: Any?
    @State private var hideTask: Task<Void, Never>?
    @State private var heartBursts: [MomentHeartBurst] = []
    @State private var clipMode = false
    @State private var clipMarkIn: Double = 0
    @State private var clipMarkOut: Double = 0
    @State private var activeClipHandle: ClipHandle?
    @State private var clipCaption = ""
    @State private var clipIsSpoiler = false
    @State private var clipSaving = false
    @State private var clipError: String?

    private let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    init(
        player: AVPlayer,
        heatmapBuckets: [Int] = [],
        likedSeconds: [Int] = [],
        isAuthenticated: Bool = false,
        onLikeMoment: ((Int) -> Void)? = nil,
        showSpoilerToggle: Bool = false,
        onClipRequest: ((Int, Int, String, Bool) async throws -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onFullscreen: @escaping () -> Void,
        @ViewBuilder markers: () -> MarkerOverlay
    ) {
        self.player = player
        self.heatmapBuckets = heatmapBuckets
        self.likedSeconds = likedSeconds
        self.isAuthenticated = isAuthenticated
        self.onLikeMoment = onLikeMoment
        self.showSpoilerToggle = showSpoilerToggle
        self.onClipRequest = onClipRequest
        self.onBack = onBack
        self.onFullscreen = onFullscreen
        self.markers = markers()
    }

    var body: some View {
        ZStack {
            WatchPlayerSurface(player: player)
                .background(Color.black)
                .contentShape(Rectangle())

            Rectangle()
                .fill(.white.opacity(0.001))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggleControlsOrPlayback() }
                .zIndex(1)

            if showControls {
                controlsLayer
                    .transition(.opacity)
                    .zIndex(2)
            }

            markers
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(3)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .clipped()
        .onAppear { attachObservers() }
        .onDisappear { detachObservers() }
        .onChange(of: isMuted) { _, muted in player.isMuted = muted }
        .onChange(of: playbackRate) { _, rate in
            if isPlaying { player.rate = rate }
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(.black.opacity(0.42))
                        .clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let onBack {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(.black.opacity(0.36))
                                .clipShape(Circle())
                                .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                    chromeButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        isMuted.toggle()
                        scheduleHide()
                    }

                    ZStack(alignment: .topTrailing) {
                        chromeButton(systemName: "gearshape.fill", active: showSpeedMenu || playbackRate != 1) {
                            withAnimation(.easeOut(duration: 0.16)) { showSpeedMenu.toggle() }
                            scheduleHide()
                        }
                        if showSpeedMenu {
                            speedMenu
                                .offset(y: 42)
                        }
                    }

                    chromeButton(systemName: "arrow.up.left.and.arrow.down.right") {
                        onFullscreen()
                    }
                }
                .padding(.top, onBack == nil ? 10 : 48)
                .padding(.horizontal, onBack == nil ? 10 : 16)

                Spacer()

                VStack(spacing: hasHeatmap ? 6 : 8) {
                    heatmapProgressBar

                    if clipMode {
                        clipEditor
                    }

                    HStack(spacing: 10) {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 32)
                        }
                        .buttonStyle(.plain)

                        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospacedDigit()

                        momentButton
                        clipButton

                        Spacer()

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
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .onAppear { scheduleHide() }
    }

    private var heatmapProgressBar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let progress = min(max(duration > 0 ? currentTime / duration : 0, 0), 1)
            let bufferProgress = min(max(duration > 0 ? buffered / duration : 0, 0), 1)
            let playedWidth = width * CGFloat(progress)
            let bufferedWidth = width * CGFloat(bufferProgress)

            ZStack(alignment: .bottomLeading) {
                if hasHeatmap {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7, weight: .bold))
                            Text("Top Moments")
                                .font(.system(size: 9, weight: .bold))
                                .textCase(.uppercase)
                        }
                        .foregroundStyle(C.watch.opacity(0.70))

                        Canvas { ctx, size in
                            drawHeatmapWave(ctx: ctx, size: size)
                        }
                        .frame(height: 22)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                        .frame(height: 2)
                    Capsule().fill(.white.opacity(0.30))
                        .frame(width: bufferedWidth, height: 2)
                    Capsule().fill(C.watch)
                        .frame(width: playedWidth, height: 2)

                    if duration > 0 {
                        ForEach(likedSeconds, id: \.self) { sec in
                            let tickX = width * CGFloat(min(max(Double(sec) / duration, 0), 1))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(C.watch)
                                .frame(width: 2, height: 7)
                                .offset(x: max(0, tickX - 1), y: -2)
                        }
                    }

                    Circle()
                        .fill(C.watch)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, playedWidth - 4))

                    if clipMode, duration > 0 {
                        let start = min(clipMarkIn, clipMarkOut)
                        let end = max(clipMarkIn, clipMarkOut)
                        let startX = width * CGFloat(start / duration)
                        let endX = width * CGFloat(end / duration)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(C.watch.opacity(0.18))
                            .frame(width: max(2, endX - startX), height: 8)
                            .offset(x: startX, y: -3)
                        clipHandleView(label: "In")
                            .offset(x: max(0, startX - 11), y: -13)
                        clipHandleView(label: "Out")
                            .offset(x: min(width - 22, max(0, endX - 11)), y: -13)
                    }
                }
                .frame(height: 2)

                ForEach(heartBursts) { burst in
                    MomentHeartBurstView()
                        .position(x: width * CGFloat(burst.progress), y: hasHeatmap ? 18 : -6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        hideTask?.cancel()
                        let pct = min(max(0, value.location.x / width), 1)
                        if clipMode {
                            updateClipHandle(to: duration * pct, phaseStarted: false)
                        } else {
                            currentTime = duration * pct
                        }
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let pct = min(max(0, value.location.x / width), 1)
                        if clipMode {
                            updateClipHandle(to: duration * pct, phaseStarted: false)
                            activeClipHandle = nil
                        } else {
                            let target = CMTime(seconds: duration * pct, preferredTimescale: 600)
                            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        scheduleHide()
                    }
            )
        }
        .frame(height: hasHeatmap ? 42 : 18)
    }

    private func clipHandleView(label: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 11)
                .background(C.watch)
                .clipShape(Capsule())
            Rectangle()
                .fill(C.watch)
                .frame(width: 2, height: 10)
        }
    }

    @ViewBuilder
    private var momentButton: some View {
        if isAuthenticated, onLikeMoment != nil {
            let sec = max(0, Int(currentTime.rounded(.down)))
            let isLiked = likedSeconds.contains(sec)
            Button {
                likeCurrentMoment()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
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

    @ViewBuilder
    private var clipButton: some View {
        if isAuthenticated, onClipRequest != nil {
            Button {
                toggleClipMode()
            } label: {
                Image(systemName: clipMode ? "scissors.circle.fill" : "scissors")
                    .font(.system(size: 13, weight: .semibold))
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
                            Image(systemName: clipIsSpoiler ? "eye.slash.fill" : "eye")
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
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
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

    private func chromeButton(systemName: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? C.watch : .white.opacity(0.88))
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.10), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var hasHeatmap: Bool {
        duration > 0 && !heatmapBuckets.isEmpty && (heatmapBuckets.max() ?? 0) > 0
    }

    private func attachObservers() {
        detachObservers()
        isMuted = player.isMuted
        isPlaying = player.rate > 0
        duration = player.currentItem?.duration.seconds.validTime ?? 0
        buffered = bufferedEnd(from: player.currentItem)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { _ in
            currentTime = player.currentTime().seconds.validTime ?? 0
            duration = player.currentItem?.duration.seconds.validTime ?? duration
            buffered = bufferedEnd(from: player.currentItem)
            isPlaying = player.rate > 0
        }
    }

    private func detachObservers() {
        hideTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func toggleControlsOrPlayback() {
        withAnimation(.easeOut(duration: 0.18)) { showControls = true }
        scheduleHide()
    }

    private func togglePlayback() {
        if player.rate > 0 {
            player.pause()
            isPlaying = false
            withAnimation(.easeOut(duration: 0.18)) { showControls = true }
            hideTask?.cancel()
        } else {
            player.rate = playbackRate
            isPlaying = true
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying, !clipMode else { return }
        hideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 3_200_000_000)
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
            withAnimation(.easeOut(duration: 0.18)) { clipMode = false }
            clipError = nil
            scheduleHide()
            return
        }

        hideTask?.cancel()
        player.pause()
        isPlaying = false
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

    private func setClipInToCurrentTime() {
        clipMarkIn = min(floor(currentTime), max(0, clipMarkOut - 1))
    }

    private func setClipOutToCurrentTime() {
        clipMarkOut = max(floor(currentTime), clipMarkIn + 1)
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
            try await onClipRequest(markIn, markOut, clipCaption.trimmingCharacters(in: .whitespacesAndNewlines), clipIsSpoiler)
            await MainActor.run {
                clipSaving = false
                clipMode = false
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

    private func likeCurrentMoment() {
        guard let onLikeMoment else { return }
        let sec = max(0, Int(currentTime.rounded(.down)))
        onLikeMoment(sec)

        let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        let burst = MomentHeartBurst(progress: progress)
        heartBursts.append(burst)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            heartBursts.removeAll { $0.id == burst.id }
        }
        scheduleHide()
    }

    private func drawHeatmapWave(ctx: GraphicsContext, size: CGSize) {
        guard hasHeatmap else { return }

        let bucketSize = 5.0
        let maxBuckets = max(2, min(Int(ceil(duration / bucketSize)) + 1, heatmapBuckets.count))
        let trimmed = Array(heatmapBuckets.prefix(maxBuckets)).map { CGFloat($0) }
        guard trimmed.count >= 2 else { return }

        let maxVal = max(1, trimmed.max() ?? 1)
        let width = size.width
        let height = size.height
        let points: [CGPoint] = trimmed.enumerated().map { idx, value in
            let x = CGFloat(idx) / CGFloat(max(1, trimmed.count - 1)) * width
            let y = height - max(2, (value / maxVal) * height * 0.90)
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
            with: .color(C.watch.opacity(0.38)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
        )

        let x = CGFloat(min(max(currentTime / duration, 0), 1)) * width
        var needle = Path()
        needle.move(to: CGPoint(x: x, y: 0))
        needle.addLine(to: CGPoint(x: x, y: height))
        ctx.stroke(needle, with: .color(.white.opacity(0.48)), style: StrokeStyle(lineWidth: 1.2))
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

private struct MomentHeartBurst: Identifiable {
    let id = UUID()
    let progress: Double
}

private enum ClipHandle {
    case markIn
    case markOut
}

private struct MomentHeartBurstView: View {
    @State private var y: CGFloat = 0
    @State private var opacity = 1.0
    @State private var scale = 0.8

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(C.watch)
            .scaleEffect(scale)
            .offset(y: y)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0)) {
                    y = -44
                    opacity = 0
                    scale = 1.25
                }
            }
    }
}

struct WatchPlayerSurface: UIViewRepresentable {
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

    var body: some View {
        HStack(spacing: 0) {
            WatchPlayerSurface(player: player)
                .frame(width: 150, height: 84)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture(perform: onExpand)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 128, alignment: .leading)

                HStack(spacing: 14) {
                    Button {
                        if player.rate > 0 { player.pause() }
                        else { player.play() }
                    } label: {
                        Image(systemName: player.rate > 0 ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 84)
            .background(Color.black.opacity(0.90))
        }
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }
}

private extension Double {
    var validTime: Double? {
        isFinite && !isNaN && self >= 0 ? self : nil
    }
}
