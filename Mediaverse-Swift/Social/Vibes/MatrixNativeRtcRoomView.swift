import LiveKit
import SwiftUI
import UIKit

enum MatrixNativeRtcError: LocalizedError, Equatable {
    case invalidService
    case invalidMembership
    case encryptedMediaNotVerified
    case adminEnablementRequired

    var errorDescription: String? {
        switch self {
        case .invalidService:
            "WeStreem calling is unavailable."
        case .invalidMembership:
            "WeStreem could not confirm your access to this call."
        case .encryptedMediaNotVerified:
            "Calls in encrypted rooms are unavailable until secure media encryption is verified."
        case .adminEnablementRequired:
            "A Vibe admin must enable calls for members in this Wave."
        }
    }
}

struct MatrixNativeRtcJoinRequest: Encodable, Sendable {
    let roomId: String
    let deviceId: String
    let intent: String
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
    let expiresInSeconds: Int
}

struct MatrixNativeRtcConnectionResponse: Decodable, Sendable {
    let connection: MatrixNativeRtcConnection
}

@MainActor
private final class MatrixNativeRtcRoomModel: NSObject, ObservableObject, RoomDelegate {
    @Published var connection: MatrixNativeRtcConnection?
    @Published var joining = false
    @Published var connected = false
    @Published var reconnecting = false
    @Published var microphoneEnabled = false
    @Published var cameraEnabled = false
    @Published var errorMessage: String?

    let liveKitRoom = Room()

    override init() {
        super.init()
        liveKitRoom.add(delegate: self)
    }

    func connect(_ connection: MatrixNativeRtcConnection) async throws {
        self.connection = connection
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await liveKitRoom.connect(
                    url: connection.url,
                    token: connection.token
                )
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
                await liveKitRoom.disconnect()
                guard attempt < 2 else { break }
                try Task.checkCancellation()
                try await Task.sleep(
                    for: .milliseconds(attempt == 0 ? 500 : 1_250)
                )
            }
        }
        self.connection = nil
        throw lastError ?? MatrixNativeRtcError.invalidService
    }

    func toggleMicrophone() async {
        guard connection?.voiceEnabled == true else { return }
        do {
            try await liveKitRoom.localParticipant.setMicrophone(
                enabled: !microphoneEnabled
            )
            microphoneEnabled.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCamera() async {
        guard connection?.videoEnabled == true else { return }
        do {
            try await liveKitRoom.localParticipant.setCamera(
                enabled: !cameraEnabled
            )
            cameraEnabled.toggle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        connection = nil
        connected = false
        reconnecting = false
        microphoneEnabled = false
        cameraEnabled = false
        await liveKitRoom.disconnect()
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
