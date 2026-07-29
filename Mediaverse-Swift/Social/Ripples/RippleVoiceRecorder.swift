import AVFoundation
import Foundation

@MainActor
final class RippleVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case paused
        case ready
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var fileURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async {
        guard state == .idle || state == .ready else { return }
        state = .requestingPermission
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            state = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ripple-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: destination, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw CocoaError(.fileWriteUnknown)
            }
            self.recorder = recorder
            fileURL = destination
            elapsedSeconds = 0
            state = .recording
            beginTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pauseOrResume() {
        guard let recorder else { return }
        switch state {
        case .recording:
            recorder.pause()
            state = .paused
            stopTimer()
        case .paused:
            recorder.record()
            state = .recording
            beginTimer()
        default:
            break
        }
    }

    func finish() {
        guard state == .recording || state == .paused else { return }
        recorder?.stop()
        stopTimer()
        elapsedSeconds = recorder?.currentTime ?? elapsedSeconds
        state = elapsedSeconds >= 1 ? .ready : .failed("Record at least one second.")
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        stopTimer()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        elapsedSeconds = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsedSeconds = recorder.currentTime
                if self.elapsedSeconds >= 600 { self.finish() }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
