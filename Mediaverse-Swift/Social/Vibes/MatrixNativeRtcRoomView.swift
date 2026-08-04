import AVFoundation
import LiveKit
import SwiftUI
import UIKit

enum MatrixNativeRtcError: LocalizedError, Equatable {
    case invalidService
    case invalidMembership
    case adminEnablementRequired
    case microphonePermissionRequired
    case cameraPermissionRequired
    case microphoneAndCameraPermissionRequired

    var errorDescription: String? {
        switch self {
        case .invalidService:
            "WeStreem calling is unavailable."
        case .invalidMembership:
            "WeStreem could not confirm your access to this call."
        case .adminEnablementRequired:
            "A Vibe admin must enable calls for members in this Wave."
        case .microphonePermissionRequired:
            "Microphone access is off. Enable it in Settings to speak; you can still hear the call."
        case .cameraPermissionRequired:
            "Camera access is off. Enable it in Settings to share video; you can still join the call."
        case .microphoneAndCameraPermissionRequired:
            "Microphone and camera access are off. Enable them in Settings; you can still join and hear the call."
        }
    }
}

@MainActor
enum MatrixNativeRtcMediaAccess {
    struct Result: Equatable, Sendable {
        let microphone: Bool
        let camera: Bool

        var error: MatrixNativeRtcError? {
            switch (microphone, camera) {
            case (true, true): nil
            case (false, true): .microphonePermissionRequired
            case (true, false): .cameraPermissionRequired
            case (false, false): .microphoneAndCameraPermissionRequired
            }
        }
    }

    static func current(hasVideo: Bool) -> Result {
        Result(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            camera: !hasVideo
                || AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        )
    }

    static func ensureCallAccessForForegroundAction(hasVideo: Bool) async -> Result {
        guard UIApplication.shared.applicationState == .active else {
            return current(hasVideo: hasVideo)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await LiveKitSDK.ensureDeviceAccess(for: [.audio])
        }
        if hasVideo,
           AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await LiveKitSDK.ensureDeviceAccess(for: [.video])
        }
        return current(hasVideo: hasVideo)
    }
}

@MainActor
enum MatrixNativeLiveKitCallAudio {
    private static var callKitLifecycleCount = 0

    static func prepareForCallKit() {
        callKitLifecycleCount += 1
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    static func activateForCallKit() {
        guard callKitLifecycleCount > 0 else { return }
        try? AudioManager.shared.setEngineAvailability(.default)
    }

    static func deactivateForCallKit() {
        guard callKitLifecycleCount > 0 else { return }
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    static func releaseCallKitLifecycle() {
        callKitLifecycleCount = max(0, callKitLifecycleCount - 1)
        if callKitLifecycleCount == 0 {
            try? AudioManager.shared.setEngineAvailability(.default)
        }
    }

    static func resetCallKitLifecycles() {
        callKitLifecycleCount = 0
        try? AudioManager.shared.setEngineAvailability(.default)
    }
}

struct MatrixNativeRtcJoinRequest: Encodable, Sendable {
    let roomId: String
    let deviceId: String
    let intent: String
    let context: String?
    let stageMode: String?
    let invitationEventId: String?
    let invitationRedemptionId: String?

    init(
        roomId: String,
        deviceId: String,
        intent: String,
        context: String?,
        stageMode: String? = nil,
        invitationEventId: String? = nil,
        invitationRedemptionId: String? = nil
    ) {
        self.roomId = roomId
        self.deviceId = deviceId
        self.intent = intent
        self.context = context
        self.stageMode = stageMode
        self.invitationEventId = invitationEventId
        self.invitationRedemptionId = invitationRedemptionId
    }
}

struct MatrixNativeRtcConnection: Decodable, Equatable, Sendable {
    let provider: String
    let url: String
    let token: String
    let roomName: String
    let canPublish: Bool
    let voiceEnabled: Bool
    let videoEnabled: Bool
    let authority: String
    let membershipEventType: String
    let mediaProtection: MatrixNativeRtcMediaSecurity
    let applicationMediaEncryption: Bool
    let expiresInSeconds: Int
    let roomId: String?
    let deviceId: String?
    let callId: String?
    let intent: String?
    let experience: String?
    let stageMode: String?
    let role: String?
    let canSubscribe: Bool
    let expiresAtMilliseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case provider, url, token, roomName, canPublish, voiceEnabled
        case videoEnabled, authority, membershipEventType, mediaProtection
        case applicationMediaEncryption, expiresInSeconds, roomId, deviceId
        case callId, intent, experience, stageMode, role, canSubscribe
        case expiresAtMilliseconds = "expiresAtMs"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        canPublish = try values.decode(Bool.self, forKey: .canPublish)
        authority = try values.decode(String.self, forKey: .authority)
        membershipEventType = try values.decode(String.self, forKey: .membershipEventType)
        mediaProtection = try values.decode(MatrixNativeRtcMediaSecurity.self, forKey: .mediaProtection)
        applicationMediaEncryption = try values.decode(Bool.self, forKey: .applicationMediaEncryption)
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        token = try values.decodeIfPresent(String.self, forKey: .token) ?? ""
        roomName = try values.decodeIfPresent(String.self, forKey: .roomName) ?? ""
        voiceEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? canPublish
        intent = try values.decodeIfPresent(String.self, forKey: .intent)
        videoEnabled = try values.decodeIfPresent(Bool.self, forKey: .videoEnabled)
            ?? (canPublish && intent == "video")
        roomId = try values.decodeIfPresent(String.self, forKey: .roomId)
        deviceId = try values.decodeIfPresent(String.self, forKey: .deviceId)
        callId = try values.decodeIfPresent(String.self, forKey: .callId)
        experience = try values.decodeIfPresent(String.self, forKey: .experience)
        stageMode = try values.decodeIfPresent(String.self, forKey: .stageMode)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        canSubscribe = try values.decodeIfPresent(Bool.self, forKey: .canSubscribe) ?? false
        expiresAtMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .expiresAtMilliseconds)
        if let expiresAtMilliseconds {
            expiresInSeconds = max(
                1,
                Int(
                    (expiresAtMilliseconds - Int64(Date().timeIntervalSince1970 * 1_000))
                        / 1_000
                )
            )
        } else {
            expiresInSeconds = try values.decode(Int.self, forKey: .expiresInSeconds)
        }
    }
}

struct MatrixNativeRtcConnectionResponse: Decodable, Sendable {
    let connection: MatrixNativeRtcConnection
}

@MainActor
private protocol MatrixNativeRtcTransportAdapter: AnyObject {
    var provider: MatrixNativeRtcMediaProvider { get }
    func connect(_ connection: MatrixNativeRtcConnection) async throws
    func setTrack(_ intent: MatrixNativeRtcTrackIntent, enabled: Bool) async throws
    func disconnect() async
}

@MainActor
private final class MatrixNativeLiveKitTransportAdapter:
    MatrixNativeRtcTransportAdapter {
    let provider = MatrixNativeRtcMediaProvider.livekit
    let room = Room()

    func connect(_ connection: MatrixNativeRtcConnection) async throws {
        try await room.connect(url: connection.url, token: connection.token)
    }

    func setTrack(_ intent: MatrixNativeRtcTrackIntent, enabled: Bool) async throws {
        switch intent {
        case .microphone:
            try await room.localParticipant.setMicrophone(enabled: enabled)
        case .camera:
            try await room.localParticipant.setCamera(enabled: enabled)
        case .screen:
            guard MatrixNativeRtcContract.permitsTrackIntent(.screen) else {
                throw MatrixNativeRtcError.invalidService
            }
            throw MatrixNativeRtcError.invalidService
        }
    }

    func disconnect() async {
        await room.disconnect()
    }
}

@MainActor
private final class MatrixNativeCloudflareRealtimeTransportAdapter:
    MatrixNativeRtcTransportAdapter {
    let provider = MatrixNativeRtcMediaProvider.cloudflareRealtime

    func connect(_ connection: MatrixNativeRtcConnection) async throws {
        _ = connection
        throw MatrixNativeRtcError.invalidService
    }

    func setTrack(_ intent: MatrixNativeRtcTrackIntent, enabled: Bool) async throws {
        _ = intent
        _ = enabled
        throw MatrixNativeRtcError.invalidService
    }

    func disconnect() async {}
}

@MainActor
final class MatrixNativeRtcRoomModel: NSObject, ObservableObject, RoomDelegate {
    @Published var connection: MatrixNativeRtcConnection?
    @Published var joining = false
    @Published var connected = false
    @Published var reconnecting = false
    @Published var microphoneEnabled = false
    @Published var cameraEnabled = false
    @Published var errorMessage: String?

    private var providerSelection: MatrixNativeRtcProviderSelection?
    private let liveKitTransport = MatrixNativeLiveKitTransportAdapter()
    private let cloudflareTransport = MatrixNativeCloudflareRealtimeTransportAdapter()
    private var activeTransport: (any MatrixNativeRtcTransportAdapter)?
    var liveKitRoom: Room { liveKitTransport.room }

    override init() {
        super.init()
        liveKitTransport.room.add(delegate: self)
    }

    func connect(_ connection: MatrixNativeRtcConnection) async throws {
        let selection = MatrixNativeRtcProviderSelection(
            serverProvider: connection.provider
        )
        guard selection.routingDecision == .livekit,
           providerSelection == nil || providerSelection == selection,
           connection.mediaProtection == .standardWebRTC,
           connection.applicationMediaEncryption == false else {
            throw MatrixNativeRtcError.invalidService
        }
        providerSelection = selection
        let transport: any MatrixNativeRtcTransportAdapter
        switch selection.routingDecision {
        case .livekit:
            transport = liveKitTransport
        case .cloudflareRealtime:
            transport = cloudflareTransport
        case .rejected:
            throw MatrixNativeRtcError.invalidService
        }
        guard activeTransport == nil || activeTransport?.provider == transport.provider else {
            throw MatrixNativeRtcError.invalidService
        }
        activeTransport = transport
        self.connection = connection
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await transport.connect(connection)
                connected = true
                reconnecting = false
                errorMessage = nil
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Call connected"
                )
                return
            } catch {
                lastError = error
                await transport.disconnect()
                guard attempt < 2 else { break }
                try Task.checkCancellation()
                try await Task.sleep(
                    for: .milliseconds(attempt == 0 ? 500 : 1_250)
                )
            }
        }
        self.connection = nil
        providerSelection = nil
        activeTransport = nil
        throw lastError ?? MatrixNativeRtcError.invalidService
    }

    func toggleMicrophone() async {
        guard connection?.voiceEnabled == true else { return }
        do {
            try await activeTransport?.setTrack(
                .microphone,
                enabled: !microphoneEnabled
            )
            microphoneEnabled.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setMicrophone(enabled: Bool) async throws {
        guard connection?.voiceEnabled == true else { return }
        try await activeTransport?.setTrack(.microphone, enabled: enabled)
        microphoneEnabled = enabled
    }

    func toggleCamera() async {
        guard connection?.videoEnabled == true else { return }
        do {
            try await activeTransport?.setTrack(
                .camera,
                enabled: !cameraEnabled
            )
            cameraEnabled.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCamera(enabled: Bool) async throws {
        guard connection?.videoEnabled == true else { return }
        try await activeTransport?.setTrack(.camera, enabled: enabled)
        cameraEnabled = enabled
    }

    func disconnect() async {
        let transport = activeTransport
        connection = nil
        providerSelection = nil
        activeTransport = nil
        connected = false
        reconnecting = false
        microphoneEnabled = false
        cameraEnabled = false
        await transport?.disconnect()
    }

    nonisolated func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch connectionState {
            case .connected:
                connected = true
                reconnecting = false
                errorMessage = nil
            case .reconnecting:
                reconnecting = true
            case .disconnected:
                reconnecting = false
                if oldConnectionState == .connected
                    || oldConnectionState == .reconnecting {
                    connected = false
                    errorMessage = "The call was interrupted. Tap Join call to reconnect."
                }
            case .connecting, .disconnecting:
                break
            @unknown default:
                break
            }
        }
    }
}

@MainActor
final class MatrixNativeIncomingCallRuntime: ObservableObject {
    static let shared = MatrixNativeIncomingCallRuntime()

    @MainActor
    private final class ActiveCall {
        let descriptor: WestreemCallDescriptor
        let model = MatrixNativeRtcRoomModel()
        var muted: Bool
        var audioSessionActive: Bool
        var task: Task<Void, Never>?
        var membershipStarted = false
        var cleanupStarted = false

        init(
            descriptor: WestreemCallDescriptor,
            muted: Bool,
            audioSessionActive: Bool
        ) {
            self.descriptor = descriptor
            self.muted = muted
            self.audioSessionActive = audioSessionActive
        }
    }

    private weak var matrixSession: MatrixNativeSessionController?
    private var calls: [UUID: ActiveCall] = [:]

    private init() {}

    var canAcceptCalls: Bool {
        // A valid system CallKit action is the user authorization for the
        // call. The optional in-app biometric lock protects app content; it
        // must not suppress a system call while the stored session still
        // exists. Logged-out devices have no token and remain fail-closed.
        SessionStorage.token != nil
    }

    func configure(matrixSession: MatrixNativeSessionController) {
        self.matrixSession = matrixSession
    }

    func prepare(
        _ descriptor: WestreemCallDescriptor,
        muted: Bool,
        audioSessionActive: Bool
    ) {
        guard calls[descriptor.uuid] == nil else { return }
        calls[descriptor.uuid] = ActiveCall(
            descriptor: descriptor,
            muted: muted,
            audioSessionActive: audioSessionActive
        )
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimePrepare,
            reason: .begin
        )
    }

    func activate(_ uuid: UUID) {
        guard let call = calls[uuid], call.task == nil else { return }
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimeActivate,
            reason: .activated
        )
        call.task = Task { [weak self, weak call] in
            guard let self, let call else { return }
            await join(call)
        }
    }

    func model(for uuid: UUID) -> MatrixNativeRtcRoomModel? {
        calls[uuid]?.model
    }

    func isHandling(_ uuid: UUID) -> Bool {
        calls[uuid] != nil
    }

    func isMuted(_ uuid: UUID) -> Bool {
        calls[uuid]?.muted ?? false
    }

    func setMuted(_ muted: Bool, callUUID: UUID) {
        guard let call = calls[callUUID] else { return }
        call.muted = muted
        applyMicrophoneState(to: call)
    }

    func setAudioSessionActive(_ active: Bool, callUUID: UUID) {
        guard let call = calls[callUUID] else { return }
        call.audioSessionActive = active
        applyMicrophoneState(to: call)
    }

    private func applyMicrophoneState(to call: ActiveCall) {
        guard call.model.connected else { return }
        Task { [weak call] in
            guard let call else { return }
            do {
                try await call.model.setMicrophone(
                    enabled: call.audioSessionActive && !call.muted
                )
            } catch {
                call.model.errorMessage = error.localizedDescription
            }
        }
    }

    func endAll() async {
        for uuid in Array(calls.keys) {
            await end(uuid, endCallKit: false)
        }
    }

    func end(_ uuid: UUID, endCallKit: Bool) async {
        guard let call = calls[uuid], !call.cleanupStarted else { return }
        call.cleanupStarted = true
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimeCleanup,
            reason: .begin
        )
        let task = call.task
        call.task = nil
        task?.cancel()
        await task?.value
        await call.model.disconnect()
        if call.membershipStarted {
            await matrixSession?.endMatrixRtcMembership(
                roomID: call.descriptor.roomID
            )
        }
        calls.removeValue(forKey: uuid)
        if endCallKit {
            await WestreemCallKitCoordinator.shared.end(uuid)
        }
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimeCleanup,
            reason: .completed
        )
    }

    private func join(_ call: ActiveCall) async {
        guard let matrixSession else {
            await fail(call, MatrixNativeRtcError.invalidMembership)
            return
        }
        call.model.joining = true
        call.model.errorMessage = nil
        do {
            // Auth and Matrix restoration can still be completing when a VoIP
            // push launches a terminated app. Wait only inside the invitation's
            // bounded lifetime and never manufacture a client-side identity.
            for _ in 0..<60 where !matrixSession.isReady {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250))
            }
            guard matrixSession.isReady else {
                throw MatrixNativeRtcError.invalidMembership
            }
            let intent: MatrixNativeRtcIntent = call.descriptor.hasVideo
                ? .video
                : .audio
            let deviceID = try await matrixSession.beginMatrixRtcMembership(
                roomID: call.descriptor.roomID,
                intent: intent,
                experience: .call
            )
            call.membershipStarted = true
            try Task.checkCancellation()
            var completedAttempts = 0
            let connection: MatrixNativeRtcConnection
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .providerJoin,
                reason: .begin
            )
            while true {
                try Task.checkCancellation()
                completedAttempts += 1
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .providerJoinRequestBegin,
                    reason: .begin
                )
                do {
                    connection = try await APIClient.shared.joinMatrixNativeRtcRoom(
                        roomID: call.descriptor.roomID,
                        deviceID: deviceID,
                        intent: intent,
                        context: "call",
                        invitationEventID: call.descriptor.eventID,
                        invitationRedemptionID: call.descriptor.redemptionID?
                            .uuidString.lowercased()
                    )
                    MatrixNativeRtcBreadcrumbRecorder.shared.record(
                        .providerJoinRequestSuccess,
                        reason: .success
                    )
                    break
                } catch {
                    MatrixNativeRtcBreadcrumbRecorder.shared.record(
                        .providerJoinRequestFailure,
                        reason: .failed
                    )
                    let serverCode: String?
                    if case APIError.matrixRtcMembershipNotVisible(_) = error {
                        serverCode = MatrixNativeRtcMembershipVisibilityRetryPolicy
                            .confirmationCode
                    } else {
                        serverCode = nil
                    }
                    guard MatrixNativeRtcMembershipVisibilityRetryPolicy.shouldRetry(
                        serverCode: serverCode,
                        completedAttempts: completedAttempts
                    ), let delay = MatrixNativeRtcMembershipVisibilityRetryPolicy
                        .delayMilliseconds(
                            afterAttempt: completedAttempts,
                            invitationExpiresAtMilliseconds: call.descriptor
                                .invitationExpiresAtMilliseconds,
                            requiresInvitationExpiry:
                                call.descriptor.eventID != nil
                        )
                    else { throw error }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(delay))
                }
            }
            try Task.checkCancellation()
            try await call.model.connect(connection)
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .providerConnected,
                reason: .success
            )
            try Task.checkCancellation()
            if connection.voiceEnabled {
                do {
                    try await call.model.setMicrophone(
                        enabled: call.audioSessionActive && !call.muted
                    )
                } catch {
                    call.model.errorMessage = error.localizedDescription
                }
            }
            if connection.videoEnabled,
               call.audioSessionActive,
               call.descriptor.hasVideo {
                do {
                    try await call.model.setCamera(enabled: true)
                } catch {
                    call.model.errorMessage = error.localizedDescription
                }
            }
            call.model.joining = false
        } catch is CancellationError {
            call.model.joining = false
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .providerJoin,
                reason: .cancelled
            )
        } catch {
            await fail(call, error)
        }
    }

    private func fail(_ call: ActiveCall, _ error: Error) async {
        call.model.joining = false
        call.model.errorMessage = error.localizedDescription
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .providerJoin,
            reason: .failed,
            error: error
        )
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimeCleanup,
            reason: .begin
        )
        await call.model.disconnect()
        if call.membershipStarted {
            await matrixSession?.endMatrixRtcMembership(
                roomID: call.descriptor.roomID
            )
        }
        calls.removeValue(forKey: call.descriptor.uuid)
        await WestreemCallKitCoordinator.shared.end(call.descriptor.uuid)
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .runtimeCleanup,
            reason: .completed
        )
    }
}

struct MatrixNativeRtcRoomView: View {
    let room: MatrixWaveSummary

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MatrixNativeRtcRoomModel()
    @State private var intent: MatrixNativeRtcIntent = .audio

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                if model.connected {
                    VStack(spacing: 16) {
                        MatrixNativeRtcVideoGrid(room: model.liveKitRoom)
                            .frame(maxWidth: .infinity, maxHeight: 500)
                        Text(
                            model.reconnecting
                                ? "Reconnecting your call…"
                                : "Vibe call access is synchronized securely"
                        )
                            .font(.caption)
                            .foregroundStyle(
                                model.reconnecting ? C.watch : C.textMuted
                            )
                            .accessibilityLabel(
                                model.reconnecting
                                    ? "Call reconnecting"
                                    : "Call connected"
                            )
                        HStack(spacing: 18) {
                            control(
                                model.microphoneEnabled
                                    ? "mic.fill"
                                    : "mic.slash.fill",
                                label: model.microphoneEnabled
                                    ? "Mute microphone"
                                    : "Unmute microphone"
                            ) {
                                Task { await model.toggleMicrophone() }
                            }
                            if model.connection?.videoEnabled == true {
                                control(
                                    model.cameraEnabled
                                        ? "video.fill"
                                        : "video.slash.fill",
                                    label: model.cameraEnabled
                                        ? "Turn camera off"
                                        : "Turn camera on"
                                ) {
                                    Task { await model.toggleCamera() }
                                }
                            }
                            control(
                                "phone.down.fill",
                                label: "Leave call",
                                destructive: true
                            ) {
                                Task { await leaveAndDismiss() }
                            }
                        }
                    }
                    .padding()
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "wave.3.right.circle.fill")
                            .font(.system(size: 62))
                            .foregroundStyle(C.watch)
                        Text("Join the live Wave")
                            .font(.title2.bold())
                            .foregroundStyle(C.text)
                        Text("Your microphone and camera remain off until you choose a call type and join.")
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .multilineTextAlignment(.center)
                        Picker("Call type", selection: $intent) {
                            Text("Voice").tag(MatrixNativeRtcIntent.audio)
                            Text("Video").tag(MatrixNativeRtcIntent.video)
                        }
                        .pickerStyle(.segmented)
                        Button {
                            Task { await join() }
                        } label: {
                            if model.joining {
                                ProgressView()
                                    .tint(C.bg)
                                    .accessibilityLabel("Connecting call")
                            } else {
                                Text("Join call").fontWeight(.bold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(C.watch)
                        .foregroundStyle(C.bg)
                        .disabled(model.joining)
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .accessibilityLabel("Call error: \(error)")
                        }
                    }
                    .padding(28)
                }
            }
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        Task { await leaveAndDismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(
            model.joining || model.connected || model.reconnecting
        )
        .onDisappear {
            Task {
                await model.disconnect()
                await matrixSession.endMatrixRtcMembership(roomID: room.id)
            }
        }
    }

    @MainActor
    private func join() async {
        guard !model.joining, !model.connected else { return }
        model.joining = true
        model.errorMessage = nil
        do {
            let deviceID = try await matrixSession.beginMatrixRtcMembership(
                roomID: room.id,
                intent: intent
            )
            let connection = try await APIClient.shared.joinMatrixNativeRtcRoom(
                roomID: room.id,
                deviceID: deviceID,
                intent: intent
            )
            try await model.connect(connection)
        } catch {
            await model.disconnect()
            await matrixSession.endMatrixRtcMembership(roomID: room.id)
            model.errorMessage = error.localizedDescription
        }
        model.joining = false
    }

    @MainActor
    private func leaveAndDismiss() async {
        await model.disconnect()
        await matrixSession.endMatrixRtcMembership(roomID: room.id)
        dismiss()
    }

    private func control(
        _ icon: String,
        label: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 54, height: 54)
                .background(
                    destructive ? Color.red : Color.white.opacity(0.14),
                    in: Circle()
                )
                .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }
}

private struct MatrixNativeRtcVideoGrid: View {
    @ObservedObject var room: Room

    private var tracks: [VideoTrack] {
        let remote = room.remoteParticipants.values.compactMap(
            \.firstCameraVideoTrack
        )
        let local = room.localParticipant.firstCameraVideoTrack.map { [$0] } ?? []
        return local + remote
    }

    var body: some View {
        if tracks.isEmpty {
            Image(systemName: "person.3.fill")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    SwiftUIVideoView(track, layoutMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .aspectRatio(9 / 16, contentMode: .fit)
                }
            }
        }
    }
}
