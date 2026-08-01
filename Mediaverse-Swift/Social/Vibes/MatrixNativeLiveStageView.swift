import LiveKit
import SwiftUI

/// A Live Stage is a Wave-hosted audio stage. Hosts and approved speakers
/// share a LiveKit lounge; everyone else listens (audience). The stage
/// state and speaker queue are canonically stored in Matrix room state:
///   • `com.westreem.live.stage.v1` — status, title, hosts, speakers
///   • `com.westreem.live.speaker.v1` — one per user, keyed by user ID
///
/// LiveKit RTC media is shared with the existing `MatrixNativeRtcRoomView`
/// infrastructure — the Live Stage is a role-gated UI on top of the same
/// LiveKit session.
struct MatrixNativeLiveStageView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MatrixNativeLiveStageModel()

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                content
            }
            .navigationTitle(model.stage?.title ?? "Live Stage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await leave() }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(C.text)
                    }
                    .accessibilityLabel("Leave Live Stage")
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
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            errorView(error)
        } else if let stage = model.stage, stage.isLive {
            stageBody(stage)
        } else {
            VStack(spacing: 14) {
                ProgressView().tint(C.watch)
                Text("Loading stage…").foregroundStyle(C.textMuted)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(C.text)
                .multilineTextAlignment(.center)
            Button("Close") { Task { await leave() } }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
        }
        .padding(28)
    }

    private func stageBody(_ stage: MatrixNativeLiveStageState) -> some View {
        VStack(spacing: 0) {
            header(stage: stage)
            speakerGrid(stage: stage)
            audienceGrid(stage: stage)
            if model.isHost, !model.pendingRequests.isEmpty {
                hostRequestDrawer
            }
            controlBar(stage: stage)
        }
    }

    private func header(stage: MatrixNativeLiveStageState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                Text(stage.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(C.text)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(C.textMuted)
                    .font(.caption)
                Text(model.hostDisplayNames.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func speakerGrid(stage: MatrixNativeLiveStageState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.textMuted)
                .padding(.horizontal, 16)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12), count: 3
                ),
                spacing: 14
            ) {
                ForEach(model.speakers(from: stage), id: \.userID) { member in
                    speakerCircle(
                        member: member,
                        talking: model.speakingUserIDs.contains(member.userID)
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func speakerCircle(
        member: MatrixNativeWaveMember,
        talking: Bool
    ) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(C.surface)
                    .overlay(
                        Text(String(member.displayName.prefix(1)))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(C.text)
                    )
                    .frame(width: 68, height: 68)
                Circle()
                    .stroke(
                        talking ? C.watch : C.borderSubtle,
                        lineWidth: talking ? 3 : 1.5
                    )
                    .frame(width: 74, height: 74)
                    .animation(
                        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.35),
                        value: talking
                    )
                if model.isHost, member.userID != model.currentUserID {
                    VStack(spacing: 4) {
                        Button {
                            Task { await model.toggleCohost(member.userID) }
                        } label: {
                            Image(systemName: model.stage?.hosts.contains(member.userID) == true
                                ? "person.badge.minus" : "person.badge.plus")
                        }
                        .accessibilityLabel(model.stage?.hosts.contains(member.userID) == true
                            ? "Remove \(member.displayName) as cohost"
                            : "Make \(member.displayName) a cohost")
                        Button {
                            Task { await model.remove(member.userID) }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .accessibilityLabel("Remove \(member.displayName) from stage")
                    }
                    .offset(x: 28, y: -28)
                }
            }
            Text(member.displayName)
                .font(.caption)
                .foregroundStyle(C.text)
                .lineLimit(1)
        }
        .accessibilityLabel(
            talking
                ? "\(member.displayName), speaking"
                : "\(member.displayName), on stage"
        )
    }

    private func audienceGrid(stage: MatrixNativeLiveStageState) -> some View {
        let audience = model.audience(from: stage)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Listening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                Spacer()
                Text("\(audience.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(audience.prefix(40), id: \.userID) { member in
                        Circle()
                            .fill(C.surface)
                            .overlay(
                                Text(String(member.displayName.prefix(1)))
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(C.text)
                            )
                            .frame(width: 32, height: 32)
                            .accessibilityLabel(member.displayName)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private var hostRequestDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand-raise queue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.textMuted)
                .padding(.horizontal, 16)
            ForEach(model.pendingRequests) { request in
                HStack(spacing: 10) {
                    Text(model.displayName(for: request.userId))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    Spacer()
                    Button("Approve") {
                        Task { await model.approve(request.userId) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .foregroundStyle(C.bg)
                    Button("Deny") {
                        Task { await model.deny(request.userId) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(C.surface)
            }
        }
        .padding(.top, 14)
    }

    private func controlBar(stage: MatrixNativeLiveStageState) -> some View {
        HStack(spacing: 18) {
            if model.isSpeakerOrHost(stage: stage) {
                Button {
                    Task { await model.toggleMicrophone() }
                } label: {
                    Image(systemName: model.microphoneOn
                        ? "mic.fill"
                        : "mic.slash.fill"
                    )
                    .font(.title2)
                    .frame(width: 54, height: 54)
                    .background(
                        model.microphoneOn ? C.watch : C.surface,
                        in: Circle()
                    )
                    .foregroundStyle(model.microphoneOn ? C.bg : C.text)
                }
                .accessibilityLabel(model.microphoneOn ? "Mute" : "Unmute")
            } else {
                Button {
                    Task { await model.raiseHand() }
                } label: {
                    Image(systemName: model.hasRequested
                        ? "hand.raised.fill"
                        : "hand.raised"
                    )
                    .font(.title2)
                    .frame(width: 54, height: 54)
                    .background(
                        model.hasRequested ? C.watch : C.surface,
                        in: Circle()
                    )
                    .foregroundStyle(model.hasRequested ? C.bg : C.text)
                }
                .accessibilityLabel(model.hasRequested
                    ? "Cancel hand-raise"
                    : "Raise hand to speak")
            }

            Spacer()

            if model.isHost {
                Button(role: .destructive) {
                    Task { await model.endStage(); await leave() }
                } label: {
                    Label("End stage", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    Task { await leave() }
                } label: {
                    Label("Leave", systemImage: "arrow.backward.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(C.text)
            }
        }
        .padding(16)
        .background(C.surface)
    }

    @MainActor
    private func leave() async {
        await model.leave()
        dismiss()
    }
}

// MARK: - View model

@MainActor
final class MatrixNativeLiveStageModel: ObservableObject {
    @Published var stage: MatrixNativeLiveStageState?
    @Published var members: [MatrixNativeWaveMember] = []
    @Published var pendingRequests: [MatrixNativeSpeakerRequest] = []
    @Published var errorMessage: String?
    @Published var microphoneOn = false
    @Published var speakingUserIDs = Set<String>()
    @Published var hasRequested = false

    var currentUserID: String?

    private weak var session: MatrixNativeSessionController?
    private var roomID: String?
    private var pollTask: Task<Void, Never>?
    // Explicitly LiveKit.Room to avoid collision with `MatrixRustSDK.Room`
    // (both modules export a `Room` symbol).
    private var liveKitRoom: LiveKit.Room?
    private var transportCanPublish: Bool?

    var isHost: Bool {
        guard let stage, let currentUserID else { return false }
        return stage.hosts.contains(currentUserID)
    }

    var hostDisplayNames: [String] {
        guard let stage else { return [] }
        return stage.hosts.map { id in
            members.first(where: { $0.userID == id })?.displayName ?? id
        }
    }

    func isSpeakerOrHost(stage: MatrixNativeLiveStageState) -> Bool {
        guard let currentUserID else { return false }
        return stage.speakers.contains(currentUserID)
            || stage.hosts.contains(currentUserID)
    }

    func speakers(
        from stage: MatrixNativeLiveStageState
    ) -> [MatrixNativeWaveMember] {
        let ids = Set(stage.speakers).union(stage.hosts)
        return members.filter { ids.contains($0.userID) }
    }

    func audience(
        from stage: MatrixNativeLiveStageState
    ) -> [MatrixNativeWaveMember] {
        let onStage = Set(stage.speakers).union(stage.hosts)
        return members.filter { !onStage.contains($0.userID) }
    }

    func displayName(for userID: String) -> String {
        members.first(where: { $0.userID == userID })?.displayName ?? userID
    }

    func begin(
        session: MatrixNativeSessionController,
        roomID: String
    ) async {
        self.session = session
        self.roomID = roomID
        await refresh()
        guard stage?.isLive == true else {
            errorMessage = "This stage has ended."
            return
        }
        await joinLounge()
        startPolling()
    }

    private func joinLounge() async {
        guard let session, let roomID else { return }
        // A Live Stage rides on top of the room's LiveKit lounge — join in
        // audio-only mode. Role-gated publishing (mic on/off) is enforced
        // client-side by the speaker/host check; the mic button is hidden
        // for the audience.
        do {
            let deviceID = try await session.beginMatrixRtcMembership(
                roomID: roomID,
                intent: .audio
            )
            guard let stage, currentUserID != nil else {
                throw MatrixNativeRtcError.invalidMembership
            }
            let connection = try await APIClient.shared.joinMatrixNativeLiveStage(
                roomID: roomID,
                deviceID: deviceID,
                expectsPublish: isSpeakerOrHost(stage: stage)
            )
            let transport = LiveKit.Room()
            try await transport.connect(url: connection.url, token: connection.token)
            liveKitRoom = transport
            transportCanPublish = connection.canPublish
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func teardown() {
        pollTask?.cancel()
        pollTask = nil
        Task { [weak self] in
            await self?.leave()
        }
    }

    func leave() async {
        pollTask?.cancel()
        pollTask = nil
        if let liveKitRoom {
            await liveKitRoom.disconnect()
            self.liveKitRoom = nil
        }
        transportCanPublish = nil
        guard let session, let roomID else { return }
        await session.endMatrixRtcMembership(roomID: roomID)
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
            let stage = try await session.liveStageState(roomID: roomID)
            let members = (try? await session.waveMembers(roomID: roomID)) ?? []
            let requests = try await session.speakerRequests(roomID: roomID)
            self.stage = stage
            self.members = members
            self.pendingRequests = requests.filter { $0.role == .request }
            if let currentUserID {
                self.hasRequested = requests.contains(where: {
                    $0.userId == currentUserID && $0.role == .request
                })
            }
            if stage == nil, !silent {
                errorMessage = "This stage has ended."
            }
            if let stage, !isSpeakerOrHost(stage: stage), microphoneOn {
                microphoneOn = false
                if let liveKitRoom {
                    do {
                        try await liveKitRoom.localParticipant.setMicrophone(enabled: false)
                    } catch {
                        await leave()
                        errorMessage = "Microphone permission was revoked; the stage connection was closed."
                    }
                }
            }
            if let stage, liveKitRoom != nil,
               transportCanPublish != isSpeakerOrHost(stage: stage) {
                // LiveKit grants are immutable. Promotion/demotion therefore
                // reconnects with a freshly authorized Matrix stage grant.
                if let liveKitRoom { await liveKitRoom.disconnect() }
                liveKitRoom = nil
                transportCanPublish = nil
                await joinLounge()
            }
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleMicrophone() async {
        guard let liveKitRoom else {
            microphoneOn = false
            errorMessage = "Microphone publishing is unavailable until the verified LiveKit stage transport is connected."
            return
        }
        do {
            try await liveKitRoom.localParticipant.setMicrophone(
                enabled: !microphoneOn
            )
            microphoneOn.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func raiseHand() async {
        guard let session, let roomID else { return }
        do {
            try await session.requestSpeaker(roomID: roomID)
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approve(_ userId: String) async {
        guard let session, let roomID else { return }
        do {
            try await session.approveSpeaker(roomID: roomID, userId: userId)
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deny(_ userId: String) async {
        guard let session, let roomID else { return }
        do {
            try await session.denySpeaker(roomID: roomID, userId: userId)
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ userId: String) async {
        guard let session, let roomID else { return }
        do {
            try await session.removeSpeaker(roomID: roomID, userId: userId)
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCohost(_ userId: String) async {
        guard let session, let roomID, let stage else { return }
        do {
            try await session.updateLiveStageCohost(
                roomID: roomID,
                userId: userId,
                add: !stage.hosts.contains(userId)
            )
            await refresh(silent: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endStage() async {
        guard let session, let roomID else { return }
        do {
            try await session.endLiveStage(roomID: roomID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Compact banner rendered atop a Wave room when a Live Stage is active.
struct MatrixNativeLiveStageBanner: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("LIVE STAGE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Spacer()
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
        .accessibilityLabel("Live Stage in progress: \(title)")
    }
}
