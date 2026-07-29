import LiveKit
import SwiftUI

@MainActor
final class EventLiveRoomModel: ObservableObject {
    @Published var connected = false
    @Published var joining = false
    @Published var microphoneEnabled = false
    @Published var cameraEnabled = false
    @Published var participantCount = 0
    @Published var errorMessage: String?

    let room = Room()
    private let slug: String
    private var connection: EventLiveConnection?

    init(slug: String) { self.slug = slug }

    func join() async {
        guard !joining, !connected else { return }
        joining = true
        errorMessage = nil
        do {
            let credentials = try await APIClient.shared.joinVibeEventLiveRoom(slug: slug)
            connection = credentials
            try await room.connect(url: credentials.url, token: credentials.token)
            connected = true
            participantCount = room.remoteParticipants.count + 1
            if credentials.canPublish && credentials.voiceEnabled {
                try await room.localParticipant.setMicrophone(enabled: true)
                microphoneEnabled = true
            }
        } catch {
            errorMessage = error.localizedDescription
            await room.disconnect()
        }
        joining = false
    }

    func toggleMicrophone() async {
        guard connection?.canPublish == true, connection?.voiceEnabled == true else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: !microphoneEnabled)
            microphoneEnabled.toggle()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleCamera() async {
        guard connection?.canPublish == true, connection?.videoEnabled == true else { return }
        do {
            try await room.localParticipant.setCamera(enabled: !cameraEnabled)
            cameraEnabled.toggle()
        } catch { errorMessage = error.localizedDescription }
    }

    func leave() async {
        await room.disconnect()
        connected = false
        microphoneEnabled = false
        cameraEnabled = false
        participantCount = 0
    }
}

struct EventLiveRoomView: View {
    @StateObject private var model: EventLiveRoomModel
    @Environment(\.dismiss) private var dismiss

    init(slug: String) {
        _model = StateObject(wrappedValue: EventLiveRoomModel(slug: slug))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                if model.connected {
                    EventParticipantVideoGrid(room: model.room)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                    Text("\(model.participantCount) in the room")
                        .font(.headline).foregroundStyle(.white)
                    HStack(spacing: 18) {
                        control(model.microphoneEnabled ? "mic.fill" : "mic.slash.fill") {
                            Task { await model.toggleMicrophone() }
                        }
                        control(model.cameraEnabled ? "video.fill" : "video.slash.fill") {
                            Task { await model.toggleCamera() }
                        }
                        control("phone.down.fill", destructive: true) {
                            Task { await model.leave(); dismiss() }
                        }
                    }
                } else {
                    ProgressView(model.joining ? "Joining live room…" : "Preparing room…")
                        .tint(.green).foregroundStyle(.white)
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await model.join() } }
                        .buttonStyle(.borderedProminent).tint(.green)
                }
            }.padding(24)
        }
        .navigationTitle("Live room")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.join() }
        .onDisappear { Task { await model.leave() } }
    }

    private func control(_ icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(width: 54, height: 54)
                .background(destructive ? Color.red : Color.white.opacity(0.14), in: Circle())
                .foregroundStyle(.white)
        }
    }
}

private struct EventParticipantVideoGrid: View {
    @ObservedObject var room: Room

    private var tracks: [VideoTrack] {
        let remote = room.remoteParticipants.values.compactMap(\.firstCameraVideoTrack)
        let local = room.localParticipant.firstCameraVideoTrack.map { [$0] } ?? []
        return local + remote
    }

    var body: some View {
        if tracks.isEmpty {
            Image(systemName: "person.3.fill")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    SwiftUIVideoView(track, layoutMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .aspectRatio(9 / 16, contentMode: .fit)
                }
            }
        }
    }
}
