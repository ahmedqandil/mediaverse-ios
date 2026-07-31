import AVKit
import SwiftUI

struct WatchPartyPlaybackLease: Decodable, Sendable {
    let videoID: String
    let playbackURL: String
    private let leaseExpiresAtValue: String

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
        case playbackURL = "playbackUrl"
        case leaseExpiresAtValue = "leaseExpiresAt"
    }

    var leaseExpiresAt: Date {
        ISO8601DateFormatter().date(from: leaseExpiresAtValue) ?? .distantPast
    }
}

/// Full-screen Watch Party viewer for a Wave (Matrix room).
///
/// Behaviour parity with the web `MatrixNativeWatchPartyPanel.tsx`:
///   • The current host (`state.host`, falling back to legacy `startedBy`) drives
///     playback state and playhead via `com.westreem.watch_party.v1`
///     room-state writes.
///   • Non-hosts observe and can tap "Sync to host" to jump to the
///     current authoritative playhead (`startedAt + elapsed`).
///   • The room member list drives the live viewer avatar strip.
///   • Ads are per-client (`PER_CLIENT_NOT_SYNCHRONIZED` on the web
///     schema) and are not synchronized across viewers.
struct MatrixNativeWatchPartyView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MatrixNativeWatchPartyModel()

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Watch Party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await leave() }
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(C.text)
                    }
                    .accessibilityLabel("Leave Watch Party")
                }
            }
        }
        .task(id: room.id) {
            model.currentUserID = matrixSession.currentMatrixUserID()
            await model.begin(session: matrixSession, roomID: room.id)
        }
        .onDisappear {
            model.teardown()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.resumePlaybackLease() }
            } else {
                model.suspendPlaybackLease()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(C.text)
                    .multilineTextAlignment(.center)
                Button("Close") { Task { await leave() } }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
            }
            .padding(28)
        } else if let state = model.state, state.isActive {
            watchExperience(state: state)
        } else {
            VStack(spacing: 14) {
                ProgressView().tint(C.watch)
                Text("Loading Watch Party…")
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private func watchExperience(state: MatrixNativeWatchPartyState) -> some View {
        VStack(spacing: 0) {
            player(state: state)
            controls(state: state)
            viewerStrip
        }
    }

    private func player(state: MatrixNativeWatchPartyState) -> some View {
        ZStack {
            Color.black
            if let player = model.player {
                VideoPlayer(player: player)
                    .onAppear {
                        if model.isHost, state.playbackState == .playing {
                            player.play()
                        } else if !model.isHost, state.playbackState == .playing {
                            player.play()
                        }
                    }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(C.watch)
                    Text("Preparing stream…")
                        .foregroundStyle(C.textMuted)
                        .font(.footnote)
                }
            }
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func controls(state: MatrixNativeWatchPartyState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                if model.isHost {
                    Button {
                        Task { await model.togglePlayback() }
                    } label: {
                        Label(
                            state.playbackState == .playing ? "Pause" : "Play",
                            systemImage: state.playbackState == .playing
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .foregroundStyle(C.bg)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(C.watch)
                            .frame(width: 8, height: 8)
                        Text("Following \(model.hostDisplayName ?? "host")")
                            .foregroundStyle(C.text)
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(C.surface, in: Capsule())

                    Button {
                        Task { await model.syncToHost() }
                    } label: {
                        Label("Sync to host", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .foregroundStyle(C.bg)
                }

                Spacer()

                if model.isHost {
                    Button(role: .destructive) {
                        Task { await model.endWatchParty(); await leave() }
                    } label: {
                        Label("End", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var viewerStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Watching now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                Spacer()
                Text("\(model.viewers.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.watch)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.viewers.prefix(30)) { viewer in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(C.surface)
                                .overlay(
                                    Text(String(viewer.displayName.prefix(1)))
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(C.text)
                                )
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle().stroke(
                                        viewer.userID == model.state?.controllingUserID
                                            ? C.watch
                                            : C.borderSubtle,
                                        lineWidth: 2
                                    )
                                )
                        }
                        .accessibilityLabel(
                            viewer.userID == model.state?.controllingUserID
                                ? "\(viewer.displayName) (host)"
                                : viewer.displayName
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(C.bg)
    }

    @MainActor
    private func leave() async {
        model.teardown()
        dismiss()
    }
}

// MARK: - View model

@MainActor
final class MatrixNativeWatchPartyModel: ObservableObject {
    @Published var state: MatrixNativeWatchPartyState?
    @Published var errorMessage: String?
    @Published var viewers: [MatrixNativeWaveMember] = []
    @Published var player: AVPlayer?

    var currentUserID: String?

    private weak var session: MatrixNativeSessionController?
    private var roomID: String?
    private var pollTask: Task<Void, Never>?
    private var isDrivingHostSync = false
    private var leasedVideoID: String?
    private var leaseExpiresAt: Date?

    var isHost: Bool {
        guard let host = state?.controllingUserID, let currentUserID else {
            return false
        }
        return host == currentUserID
    }

    var hostDisplayName: String? {
        guard let host = state?.controllingUserID else { return nil }
        return viewers.first(where: { $0.userID == host })?.displayName
    }

    func begin(
        session: MatrixNativeSessionController,
        roomID: String
    ) async {
        self.session = session
        self.roomID = roomID
        await refresh()
        startPolling()
    }

    func teardown() {
        pollTask?.cancel()
        pollTask = nil
        player?.pause()
        player = nil
        leasedVideoID = nil
        leaseExpiresAt = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.refresh(silent: true)
            }
        }
    }

    private func refresh(silent: Bool = false) async {
        guard let session, let roomID else { return }
        do {
            let newState = try await session.watchPartyState(roomID: roomID)
            let members = (try? await session.waveMembers(roomID: roomID)) ?? []
            self.state = newState
            self.viewers = members
            if newState == nil, !silent {
                errorMessage = "This Watch Party has ended."
            }
            await configurePlayerIfNeeded(state: newState)
            applyRemotePlaybackIfNeeded(state: newState)
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func configurePlayerIfNeeded(
        state: MatrixNativeWatchPartyState?
    ) async {
        guard let state, state.isActive else {
            player?.pause()
            player = nil
            return
        }
        if leasedVideoID != state.videoId || (leaseExpiresAt ?? .distantPast) <= Date() {
            do {
                let lease = try await APIClient.shared.fetchWatchPartyLease(videoID: state.videoId)
                guard lease.videoID == state.videoId,
                      lease.leaseExpiresAt > Date(),
                      let url = URL(string: lease.playbackURL),
                      url.scheme == "https" else {
                    throw APIError.invalidResponse("The playback lease is invalid")
                }
                leasedVideoID = state.videoId
                leaseExpiresAt = lease.leaseExpiresAt
                if (player?.currentItem?.asset as? AVURLAsset)?.url != url {
                    player = AVPlayer(url: url)
                }
            } catch {
                suspendPlaybackLease()
                errorMessage = "Video access could not be revalidated. Playback is paused."
            }
            return
        }
    }

    func suspendPlaybackLease() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        leasedVideoID = nil
        leaseExpiresAt = nil
    }

    func resumePlaybackLease() async {
        guard let state else { return }
        errorMessage = nil
        await configurePlayerIfNeeded(state: state)
        applyRemotePlaybackIfNeeded(state: state)
    }

    /// Non-hosts follow the room-state playback flag; hosts control locally.
    private func applyRemotePlaybackIfNeeded(
        state: MatrixNativeWatchPartyState?
    ) {
        guard let state, state.isActive, !isHost, let player else { return }
        var targetMs = state.playheadMs
        if state.playbackState == .playing {
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            targetMs += max(0, now - (state.lastUpdatedAt ?? state.startedAt))
        }
        let currentMs = Int64(CMTimeGetSeconds(player.currentTime()) * 1_000)
        let driftMs = targetMs - currentMs
        switch state.playbackState {
        case .playing:
            if player.rate == 0 || abs(driftMs) > 5_000 {
                player.seek(to: CMTime(seconds: Double(targetMs) / 1_000, preferredTimescale: 600))
                player.play()
            } else if abs(driftMs) > 1_500 {
                player.rate = driftMs > 0 ? 1.05 : 0.95
            } else {
                player.rate = 1
            }
        case .paused:
            player.pause()
            if abs(driftMs) > 1_500 {
                player.seek(to: CMTime(seconds: Double(targetMs) / 1_000, preferredTimescale: 600))
            }
        }
    }

    func togglePlayback() async {
        guard let session, let roomID, let state, isHost, let player else {
            return
        }
        // The host's local player is the source of truth for playhead.
        let newPlayback: MatrixNativeWatchPartyPlaybackState =
            state.playbackState == .playing ? .paused : .playing
        switch newPlayback {
        case .playing: player.play()
        case .paused: player.pause()
        }
        let playheadMs = Int64(
            CMTimeGetSeconds(player.currentTime()) * 1_000
        )
        do {
            try await session.updateWatchPartyPlayback(
                roomID: roomID,
                playbackState: newPlayback,
                playheadMs: playheadMs
            )
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncToHost() async {
        guard let state, let player else { return }
        // Compute authoritative playhead from the last host mutation, not from
        // party creation (which would over-seek after every pause/resume).
        var targetMs = state.playheadMs
        if state.playbackState == .playing {
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            targetMs += max(0, now - (state.lastUpdatedAt ?? state.startedAt))
        }
        let time = CMTime(
            seconds: Double(targetMs) / 1_000,
            preferredTimescale: 600
        )
        // AVPlayer.seek returns Bool for the async variant; discard.
        _ = await player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if state.playbackState == .playing {
            player.play()
        }
    }

    func endWatchParty() async {
        guard let session, let roomID else { return }
        do {
            try await session.endWatchParty(roomID: roomID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Compact banner rendered atop a Wave room when a Watch Party is active.
/// Tapping opens `MatrixNativeWatchPartyView` as a sheet.
struct MatrixNativeWatchPartyBanner: View {
    let viewerCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .foregroundStyle(C.watch)
                Text("Watching Now")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(C.text)
                Spacer()
                Text("\(viewerCount)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(C.watch)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(C.surface)
            .overlay(
                Rectangle()
                    .fill(C.borderSubtle)
                    .frame(height: 1),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch Party active with \(viewerCount) viewers")
    }
}
