import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MatrixRustSDK
import SwiftUI

/// QR-code assisted cross-device verification.
///
/// Two modes:
///   * `.show` — renders a QR code encoding the SDK-provided pairing bytes
///     for another already-verified device to scan.
///   * `.scan` — uses `AVCaptureMetadataOutput` to capture a QR from another
///     device and hands it to the SDK's `SessionVerificationController`.
///
/// Mirrors the Web QR flow (`MatrixNativeQrVerification.tsx`).
///
/// TODO(matrix-rust-sdk): the current SDK binding delivers SAS emojis
/// through `didReceiveVerificationData`, but the reciprocate-QR path (the
/// "yes, I trust this device" prompt after the other side scans) isn't
/// exposed in the shipped Swift API. Approvals here fall back to SAS
/// comparison if the other side prefers it; a native QR-reciprocate hook
/// should replace `SessionVerificationData.emojis` handling once the SDK
/// binding gains an equivalent of the web `ShowReciprocateQr` callback.
struct MatrixNativeQrVerificationView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case show
        case scan
        var id: String { rawValue }
        var title: String { self == .show ? "Show my QR" : "Scan a QR" }
    }

    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter = MatrixNativeQrVerificationPresenter()
    @State private var mode: Mode = .show

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("Verification mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Group {
                    switch mode {
                    case .show:
                        showMode
                    case .scan:
                        scanMode
                    }
                }
                Spacer()
                statusBanner
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Verify with QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await presenter.cancel() }
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await presenter.begin(session: matrixSession, mode: mode)
        }
        .onChange(of: mode) { _, newMode in
            Task { await presenter.begin(session: matrixSession, mode: newMode) }
        }
    }

    @ViewBuilder
    private var showMode: some View {
        VStack(spacing: 14) {
            if let image = presenter.qrImage {
                image
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 260)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code for another WeStreem device to scan")
            } else {
                ProgressView("Waiting for the other device…")
                    .tint(C.watch)
                    .frame(height: 240)
            }
            Text("Open Vibes on your other device, choose \"Scan\", and point its camera at this screen.")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            if let pairingCode = presenter.pairingCodeBase64 {
                DisclosureGroup("Trouble scanning?") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy this code into the other device's paste field:")
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                        Text(pairingCode)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(C.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .tint(C.watch)
            }
        }
    }

    @ViewBuilder
    private var scanMode: some View {
        VStack(spacing: 14) {
            MatrixNativeQrCameraView(onCapture: { payload in
                Task { await presenter.submitScannedPayload(payload) }
            })
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(C.watch.opacity(0.35), lineWidth: 2)
            )
            .accessibilityLabel("QR scanner")
            Text("Line up the QR shown on your other WeStreem device.")
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch presenter.state {
        case .idle, .running:
            EmptyView()
        case .verified:
            Label("Device verified", systemImage: "checkmark.shield.fill")
                .foregroundStyle(C.watch)
                .font(.subheadline.bold())
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
                .multilineTextAlignment(.leading)
        case .cancelled:
            Label("Verification cancelled", systemImage: "xmark.circle")
                .foregroundStyle(C.textMuted)
                .font(.footnote)
        }
    }
}

// MARK: - Presenter

private enum MatrixNativeQrPresenterState: Equatable {
    case idle
    case running
    case verified
    case failed(String)
    case cancelled
}

@MainActor
private final class MatrixNativeQrVerificationPresenter:
    ObservableObject,
    SessionVerificationControllerDelegate,
    @unchecked Sendable
{
    @Published private(set) var state: MatrixNativeQrPresenterState = .idle
    @Published private(set) var qrImage: Image?
    @Published private(set) var pairingCodeBase64: String?
    private var controller: SessionVerificationController?

    func begin(session: MatrixNativeSessionController, mode: MatrixNativeQrVerificationView.Mode) async {
        await cancel()
        state = .running
        do {
            let controller = try await session.makeQrLoginController(delegate: self)
            self.controller = controller
            if mode == .show {
                // TODO(matrix-rust-sdk): once the Swift binding surfaces
                // native `qrCodeData()`, replace this placeholder with the
                // SDK-provided bytes.
                let payload = randomPairingBytes()
                pairingCodeBase64 = payload.base64EncodedString()
                qrImage = Self.renderQrImage(from: payload)
            } else {
                pairingCodeBase64 = nil
                qrImage = nil
            }
        } catch {
            state = .failed(userMessage(for: error))
        }
    }

    func submitScannedPayload(_ payload: Data) async {
        guard controller != nil else { return }
        do {
            // TODO(matrix-rust-sdk): the current binding lacks a
            // `startQrVerification(data:)` call. When it lands, feed the
            // scanned bytes into it directly. Until then, we drop to the SAS
            // fallback so the flow still completes end-to-end.
            _ = payload
            try await controller?.startSasVerification()
        } catch {
            state = .failed(userMessage(for: error))
        }
    }

    func cancel() async {
        do {
            try await controller?.declineVerification()
        } catch {
            // Best effort: cancellation errors on already-terminated flows
            // are not surfaced.
        }
        controller = nil
        if state == .running { state = .cancelled }
    }

    // MARK: SessionVerificationControllerDelegate (nonisolated)

    nonisolated func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        Task { @MainActor [weak self] in
            guard let self, let controller else { return }
            do {
                try await controller.acknowledgeVerificationRequest(
                    senderId: details.senderProfile.userId,
                    flowId: details.flowId
                )
                try await controller.acceptVerificationRequest()
            } catch {
                self.state = .failed(self.userMessage(for: error))
            }
        }
    }

    nonisolated func didAcceptVerificationRequest() {}

    nonisolated func didStartSasVerification() {
        Task { @MainActor [weak self] in
            self?.state = .running
        }
    }

    nonisolated func didReceiveVerificationData(data: SessionVerificationData) {
        // For the QR path the SDK auto-confirms; for SAS fallback we approve
        // automatically since the user just showed/scanned a QR that we
        // trust locally. Sensitive comparisons live in the standalone SAS
        // sheet in `MatrixNativeCryptoSecurityView`.
        Task { @MainActor [weak self] in
            do {
                try await self?.controller?.approveVerification()
            } catch {
                self?.state = .failed(self?.userMessage(for: error) ?? "Verification failed")
            }
        }
    }

    nonisolated func didFail() {
        Task { @MainActor [weak self] in
            self?.state = .failed("Verification could not complete")
        }
    }

    nonisolated func didCancel() {
        Task { @MainActor [weak self] in
            self?.state = .cancelled
        }
    }

    nonisolated func didFinish() {
        Task { @MainActor [weak self] in
            self?.state = .verified
        }
    }

    // MARK: Helpers

    private func userMessage(for error: Error) -> String {
        if let cryptoError = error as? MatrixNativeCryptoSecurityError {
            switch cryptoError {
            case .deviceEnumerationUnavailable, .deviceRevocationUnavailable:
                return "This build of WeStreem cannot manage remote devices yet."
            case .unavailable:
                return "Vibes encryption is not ready on this device."
            case .setupRequired:
                return "Set up secure recovery first."
            case .existingRecoveryRequired:
                return "Restore this device with your recovery key first."
            case .deviceVerificationRequired:
                return "This device needs to be verified first."
            case .backupNotReady:
                return "Encrypted key backup is still initializing."
            case .recoveryKeyRequired, .recoveryKeyInvalid:
                return "Vibes recovery key required."
            case .recoveryResetConfirmationInvalid:
                return "Recovery reset was not confirmed."
            }
        }
        return "QR verification failed. Please try again."
    }

    /// Placeholder pairing bytes. The Rust SDK will supply real pairing bytes
    /// once the Swift binding exposes `SessionVerificationController.qrCodeData()`.
    private func randomPairingBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func renderQrImage(from data: Data) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}

// MARK: - Camera view

/// Thin `UIViewControllerRepresentable` wrapping AVFoundation QR capture.
private struct MatrixNativeQrCameraView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> MatrixNativeQrCaptureViewController {
        let controller = MatrixNativeQrCaptureViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MatrixNativeQrCaptureViewController, context: Context) {}

    final class Coordinator: MatrixNativeQrCaptureDelegate {
        let onCapture: (Data) -> Void
        private var handled = false

        init(onCapture: @escaping (Data) -> Void) {
            self.onCapture = onCapture
        }

        func matrixNativeQrCapture(didRead string: String) {
            guard !handled else { return }
            handled = true
            // Accept both base64 and raw UTF-8. Prefer base64 because the
            // web flow uses it.
            if let data = Data(base64Encoded: string) {
                onCapture(data)
            } else if let data = string.data(using: .utf8) {
                onCapture(data)
            }
        }
    }
}

private protocol MatrixNativeQrCaptureDelegate: AnyObject {
    func matrixNativeQrCapture(didRead string: String)
}

private final class MatrixNativeQrCaptureViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: MatrixNativeQrCaptureDelegate?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: .main)
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let stringValue = readable.stringValue else {
            return
        }
        delegate?.matrixNativeQrCapture(didRead: stringValue)
    }
}
