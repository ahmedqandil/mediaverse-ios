import MatrixRustSDK
import SwiftUI
import UIKit

struct MatrixNativeCryptoSecurityView: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: MatrixNativeCryptoSnapshot?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var recoveryKeyInput = ""
    @State private var generatedRecoveryKey: String?
    @State private var errorMessage: String?
    @State private var showsRecoveryEntry = false
    @State private var showsVerification = false
    @State private var showsQrVerification = false
    @State private var confirmsReset = false
    @State private var resetConfirmation = ""
    let requiredForAction: Bool
    let onReady: (() -> Void)?

    init(
        requiredForAction: Bool = false,
        onReady: (() -> Void)? = nil
    ) {
        self.requiredForAction = requiredForAction
        self.onReady = onReady
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Checking Vibes security…")
                        .tint(C.watch)
                } else {
                    Form {
                        encryptionSection
                        recoverySection
                        devicesSection
                        limitationSection

                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Vibes Security")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(generatedRecoveryKey != nil)
                        .accessibilityHint(
                            generatedRecoveryKey == nil
                                ? ""
                                : "Save and confirm the recovery key before closing."
                        )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Refresh Vibes security")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(generatedRecoveryKey != nil)
        .task { await load() }
        .sheet(isPresented: $showsRecoveryEntry) {
            recoveryEntrySheet
        }
        .sheet(isPresented: $showsVerification, onDismiss: {
            Task { await load() }
        }) {
            MatrixNativeDeviceVerificationView()
                .environmentObject(matrixSession)
        }
        .sheet(isPresented: $showsQrVerification, onDismiss: {
            Task { await load() }
        }) {
            MatrixNativeQrVerificationView()
                .environmentObject(matrixSession)
        }
        .alert("Replace the recovery key?", isPresented: $confirmsReset) {
            TextField(MatrixNativeRecoveryResetPolicy.confirmation, text: $resetConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { resetConfirmation = "" }
            Button("Replace Key", role: .destructive) {
                Task { await resetRecoveryKey() }
            }
            .disabled(resetConfirmation != MatrixNativeRecoveryResetPolicy.confirmation)
        } message: {
            Text("Existing copies of the old recovery key will stop working. Type \(MatrixNativeRecoveryResetPolicy.confirmation) exactly, then save the new key before leaving this screen.")
        }
    }

    private var encryptionSection: some View {
        Section("Encrypted Vibes") {
            securityRow(
                title: "This device",
                value: verificationLabel,
                icon: snapshot?.verification == .verified
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill",
                color: snapshot?.verification == .verified ? C.watch : .orange
            )
            securityRow(
                title: "Room keys",
                value: snapshot?.canReadEligibleEncryptedRooms == true
                    ? "Protected and recoverable"
                    : "Recovery or verification required",
                icon: "lock.fill",
                color: snapshot?.canReadEligibleEncryptedRooms == true ? C.watch : .orange
            )

            if snapshot?.verification != .verified {
                Button {
                    showsVerification = true
                } label: {
                    Label("Verify this device", systemImage: "checkmark.shield")
                }
                .disabled(isWorking)
                Button {
                    showsQrVerification = true
                } label: {
                    Label("Verify with QR code", systemImage: "qrcode.viewfinder")
                }
                .disabled(isWorking)
            }

            if requiredForAction,
               snapshot?.canReadEligibleEncryptedRooms == true,
               generatedRecoveryKey == nil {
                Button {
                    onReady?()
                    dismiss()
                } label: {
                    Label("Continue securely", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
            }
        }
    }

    private var recoverySection: some View {
        Section("Recovery and backup") {
            securityRow(
                title: "Recovery",
                value: snapshot?.recovery.rawValue.capitalized ?? "Unknown",
                icon: "key.fill",
                color: snapshot?.recovery == .enabled ? C.watch : .orange
            )
            securityRow(
                title: "Encrypted key backup",
                value: backupLabel,
                icon: "externaldrive.fill.badge.checkmark",
                color: snapshot?.backup == .enabled ? C.watch : .orange
            )

            if snapshot?.recovery == .enabled {
                Button {
                    showsRecoveryEntry = true
                } label: {
                    Label("Recover this device", systemImage: "key.viewfinder")
                }
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    Label("Replace recovery key", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking)
            } else {
                Button {
                    Task { await enableRecovery() }
                } label: {
                    Label("Set up secure recovery", systemImage: "lock.badge.plus")
                }
                .disabled(isWorking)
            }

            if let generatedRecoveryKey {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Save this key now", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("WeStreem does not store this key. It cannot be shown again after you close this screen.")
                        .font(.footnote)
                        .foregroundStyle(C.textMuted)
                    Text(generatedRecoveryKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        UIPasteboard.general.setItems(
                            [["public.utf8-plain-text": generatedRecoveryKey]],
                            options: [
                                .localOnly: true,
                                .expirationDate: Date().addingTimeInterval(120),
                            ]
                        )
                    } label: {
                        Label("Copy recovery key", systemImage: "doc.on.doc")
                    }
                    Button {
                        acknowledgeGeneratedRecoveryKey()
                    } label: {
                        Label(
                            requiredForAction
                                ? "I saved it — continue"
                                : "I saved it — hide",
                            systemImage: "checkmark.shield"
                        )
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var devicesSection: some View {
        Section("Your devices") {
            VStack(alignment: .leading, spacing: 5) {
                Text("This iPhone")
                    .font(.headline)
                Text(snapshot?.currentDeviceID ?? "Unavailable")
                    .font(.caption.monospaced())
                    .foregroundStyle(C.textMuted)
                if let fingerprint = snapshot?.currentDeviceFingerprint {
                    Text("Fingerprint \(fingerprint)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(C.textTertiary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)

            if snapshot?.hasOtherVerifiableDevices == true {
                Label("Another verified device can approve this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.footnote)
            } else if snapshot?.isLastDevice == true {
                Label("This is your last known Vibes device", systemImage: "iphone")
                    .font(.footnote)
            }
        }
    }

    private var limitationSection: some View {
        Section("Device management") {
            NavigationLink {
                MatrixNativeDeviceListView()
                    .environmentObject(matrixSession)
            } label: {
                Label("All devices", systemImage: "list.bullet.rectangle.portrait")
            }
            Label(
                "Sign out of any WeStreem session that isn't yours from the devices list.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(C.textMuted)
        }
    }

    private var recoveryEntrySheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Recovery key", text: $recoveryKeyInput)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The key is processed securely on this device. WeStreem never stores it.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg)
            .navigationTitle("Recover encrypted Vibes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recoveryKeyInput = ""
                        showsRecoveryEntry = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recover") {
                        Task { await recover() }
                    }
                    .disabled(recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var verificationLabel: String {
        switch snapshot?.verification {
        case .verified: "Verified"
        case .unverified: "Not verified"
        case .unknown, nil: "Unknown"
        }
    }

    private var backupLabel: String {
        guard let snapshot else { return "Unknown" }
        if snapshot.backup == .enabled { return "Enabled" }
        if snapshot.backupExistsOnServer { return "Exists — recovery required" }
        return snapshot.backup.rawValue.capitalized
    }

    private func acknowledgeGeneratedRecoveryKey() {
        if let generatedRecoveryKey,
           UIPasteboard.general.string == generatedRecoveryKey {
            UIPasteboard.general.items = []
        }
        generatedRecoveryKey = nil
        if requiredForAction {
            onReady?()
            dismiss()
        }
    }

    private func securityRow(
        title: String,
        value: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func load() async {
        isLoading = snapshot == nil
        do {
            snapshot = try await matrixSession.cryptoSecuritySnapshot()
            errorMessage = nil
        } catch {
            errorMessage = "Vibes encryption status could not be verified. Encrypted actions remain unavailable."
        }
        isLoading = false
    }

    @MainActor
    private func enableRecovery() async {
        isWorking = true
        defer { isWorking = false }
        do {
            generatedRecoveryKey = try await matrixSession.enableCryptoRecovery(passphrase: nil)
            await load()
        } catch {
            errorMessage = "Secure Vibes recovery could not be enabled."
        }
    }

    @MainActor
    private func recover() async {
        isWorking = true
        defer {
            isWorking = false
            recoveryKeyInput = ""
        }
        do {
            try await matrixSession.recoverCryptoIdentity(recoveryKey: recoveryKeyInput)
            showsRecoveryEntry = false
            await load()
        } catch {
            errorMessage = "The Vibes recovery key could not restore this device."
        }
    }

    @MainActor
    private func resetRecoveryKey() async {
        isWorking = true
        defer {
            isWorking = false
            resetConfirmation = ""
        }
        do {
            generatedRecoveryKey = try await matrixSession.resetCryptoRecoveryKey(
                confirmation: resetConfirmation
            )
            await load()
        } catch {
            errorMessage = "The Vibes recovery key could not be replaced."
        }
    }
}

private enum MatrixNativeVerificationFlowState: Equatable {
    case idle
    case requesting
    case accepted
    case comparing([String])
    case verified
    case cancelled
    case failed
}

@MainActor
private final class MatrixNativeDeviceVerificationPresenter:
    ObservableObject,
    SessionVerificationControllerDelegate,
    @unchecked Sendable
{
    @Published private(set) var state = MatrixNativeVerificationFlowState.idle
    private var controller: SessionVerificationController?

    func begin(session: MatrixNativeSessionController) async {
        guard state == .idle || state == .failed || state == .cancelled else { return }
        state = .requesting
        do {
            let controller = try await session.makeDeviceVerificationController(delegate: self)
            self.controller = controller
            try await controller.requestDeviceVerification()
        } catch {
            state = .failed
        }
    }

    func startComparison() async {
        do {
            try await controller?.startSasVerification()
        } catch {
            state = .failed
        }
    }

    func approve() async {
        do {
            try await controller?.approveVerification()
        } catch {
            state = .failed
        }
    }

    func decline() async {
        do {
            try await controller?.declineVerification()
        } catch {
            state = .failed
        }
    }

    nonisolated func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        Task { @MainActor [weak self] in
            guard let self, let controller else { return }
            do {
                try await controller.acknowledgeVerificationRequest(
                    senderId: details.senderProfile.userId,
                    flowId: details.flowId
                )
                try await controller.acceptVerificationRequest()
                state = .accepted
            } catch {
                state = .failed
            }
        }
    }

    nonisolated func didAcceptVerificationRequest() {
        Task { @MainActor [weak self] in self?.state = .accepted }
    }

    nonisolated func didStartSasVerification() {
        Task { @MainActor [weak self] in self?.state = .accepted }
    }

    nonisolated func didReceiveVerificationData(data: SessionVerificationData) {
        let values: [String]
        switch data {
        case .emojis(let emojis, _):
            values = emojis.map { "\($0.symbol()) \($0.description())" }
        case .decimals(let decimals):
            values = decimals.map(String.init)
        }
        Task { @MainActor [weak self] in self?.state = .comparing(values) }
    }

    nonisolated func didFail() {
        Task { @MainActor [weak self] in self?.state = .failed }
    }

    nonisolated func didCancel() {
        Task { @MainActor [weak self] in self?.state = .cancelled }
    }

    nonisolated func didFinish() {
        Task { @MainActor [weak self] in self?.state = .verified }
    }
}

private struct MatrixNativeDeviceVerificationView: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter = MatrixNativeDeviceVerificationPresenter()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: verificationIcon)
                    .font(.system(size: 50))
                    .foregroundStyle(C.watch)
                    .accessibilityHidden(true)
                Text(verificationTitle)
                    .font(.title2.bold())
                    .foregroundStyle(C.text)
                Text(verificationMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(C.textMuted)

                if case .comparing(let values) = presenter.state {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            Text(value)
                                .font(.subheadline.bold())
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .accessibilityLabel("Security comparison")

                    HStack {
                        Button("They do not match", role: .destructive) {
                            Task { await presenter.decline() }
                        }
                        .buttonStyle(.bordered)
                        Button("They match") {
                            Task { await presenter.approve() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(C.watch)
                    }
                } else if presenter.state == .accepted {
                    Button("Compare security symbols") {
                        Task { await presenter.startComparison() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                } else if presenter.state == .failed || presenter.state == .cancelled {
                    Button("Try again") {
                        Task { await presenter.begin(session: matrixSession) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                }
                Spacer()
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Verify Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await presenter.begin(session: matrixSession) }
    }

    private var verificationIcon: String {
        presenter.state == .verified ? "checkmark.shield.fill" : "lock.shield"
    }

    private var verificationTitle: String {
        switch presenter.state {
        case .idle, .requesting: "Contacting your devices"
        case .accepted: "Verification accepted"
        case .comparing: "Compare both devices"
        case .verified: "Device verified"
        case .cancelled: "Verification cancelled"
        case .failed: "Verification unavailable"
        }
    }

    private var verificationMessage: String {
        switch presenter.state {
        case .idle, .requesting:
            "Approve this request on another verified WeStreem device."
        case .accepted:
            "Start a secure symbol comparison on both devices."
        case .comparing:
            "Confirm only if every symbol appears in the same order on both devices."
        case .verified:
            "This iPhone can now trust your secure WeStreem identity."
        case .cancelled:
            "No trust change was made."
        case .failed:
            "WeStreem could not complete verification. No trust change was made."
        }
    }
}
