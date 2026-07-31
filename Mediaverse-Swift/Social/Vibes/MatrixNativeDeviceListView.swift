import MatrixRustSDK
import SwiftUI

/// Web parity: lists every remote Matrix device for the current user with a
/// current-device highlight, verified badge, and per-row + bulk sign-out.
///
/// The heavy lifting sits in `MatrixSessionCoordinator.matrixDevices()` /
/// `.revokeMatrixDevice(deviceID:)`. If the shipped Rust SDK doesn't expose
/// device enumeration yet, those calls throw
/// `MatrixNativeCryptoSecurityError.deviceEnumerationUnavailable`; the UI
/// catches that and shows an "unavailable" hint instead of destructive
/// actions so we never render stale trust information.
struct MatrixNativeDeviceListView: View {
    @EnvironmentObject private var matrixSession: MatrixNativeSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [MatrixNativeDevice] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var unavailable = false
    @State private var confirmSignOutAll = false
    @State private var confirmSignOut: MatrixNativeDevice?

    var body: some View {
        List {
            if unavailable {
                Section {
                    Label(
                        "Device management is not available in this build. Update WeStreem to see and sign out other sessions.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
                }
            } else {
                currentSection
                otherSection
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if let infoMessage {
                Section {
                    Label(infoMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(C.watch)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isWorking || isLoading)
                .accessibilityLabel("Refresh devices")
            }
            if !unavailable, !otherDevices.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        confirmSignOutAll = true
                    } label: {
                        Text("Sign out other sessions")
                            .font(.footnote)
                    }
                    .disabled(isWorking)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert("Sign out all other sessions?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                Task { await signOutAllOthers() }
            }
        } message: {
            Text("This will end every other WeStreem session that shares your account. You may need to re-verify them later.")
        }
        .alert(
            confirmSignOut.map { "Sign out \($0.displayName ?? $0.id)?" } ?? "",
            isPresented: Binding(
                get: { confirmSignOut != nil },
                set: { if !$0 { confirmSignOut = nil } }
            ),
            presenting: confirmSignOut,
            actions: { device in
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    Task { await signOut(device: device) }
                }
            },
            message: { _ in
                Text("This session will lose access to encrypted Vibes until it verifies again.")
            }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentSection: some View {
        if let current = currentDevice {
            Section("This session") {
                deviceRow(current)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var otherSection: some View {
        Section("Other sessions") {
            if isLoading && devices.isEmpty {
                HStack {
                    ProgressView()
                        .tint(C.watch)
                    Text("Loading devices…")
                        .foregroundStyle(C.textMuted)
                }
            } else if otherDevices.isEmpty {
                Text("No other active sessions.")
                    .font(.footnote)
                    .foregroundStyle(C.textMuted)
            } else {
                ForEach(otherDevices) { device in
                    deviceRow(device)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                confirmSignOut = device
                            } label: {
                                Label("Sign out", systemImage: "power")
                            }
                            .disabled(isWorking)
                        }
                }
            }
        }
    }

    // MARK: - Rows

    private func deviceRow(_ device: MatrixNativeDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName(for: device))
                .font(.title3)
                .foregroundStyle(device.isCurrent ? C.watch : C.text)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.displayName ?? device.id)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    if device.isVerified {
                        Label("Verified", systemImage: "checkmark.shield.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(C.watch)
                            .accessibilityLabel("Verified device")
                    } else {
                        Label("Unverified", systemImage: "exclamationmark.shield.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Unverified device")
                    }
                }
                Text(device.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(C.textTertiary)
                    .textSelection(.enabled)
                if let lastSeen = device.lastSeenAt {
                    Text("Last active \(lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                if let ip = device.lastSeenIP, !ip.isEmpty {
                    Text("From \(ip)")
                        .font(.caption2)
                        .foregroundStyle(C.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func iconName(for device: MatrixNativeDevice) -> String {
        let name = (device.displayName ?? "").lowercased()
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("mac") { return "laptopcomputer" }
        if name.contains("android") { return "candybarphone" }
        if name.contains("web") || name.contains("chrome") || name.contains("firefox") || name.contains("safari") {
            return "safari"
        }
        return device.isCurrent ? "iphone.gen3.radiowaves.left.and.right" : "desktopcomputer"
    }

    // MARK: - Derived state

    private var currentDevice: MatrixNativeDevice? {
        devices.first(where: { $0.isCurrent })
    }

    private var otherDevices: [MatrixNativeDevice] {
        devices.filter { !$0.isCurrent }
    }

    // MARK: - Actions

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            devices = try await matrixSession.matrixDevices()
            unavailable = false
        } catch MatrixNativeCryptoSecurityError.deviceEnumerationUnavailable {
            unavailable = true
            devices = []
        } catch MatrixNativeCryptoSecurityError.deviceRevocationUnavailable {
            unavailable = true
            devices = []
        } catch {
            errorMessage = "Devices could not be loaded."
        }
    }

    @MainActor
    private func signOut(device: MatrixNativeDevice) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await matrixSession.revokeMatrixDevice(deviceID: device.id)
            infoMessage = "\(device.displayName ?? device.id) signed out."
            await load()
        } catch MatrixNativeCryptoSecurityError.deviceRevocationUnavailable {
            errorMessage = "Sign-out is not available in this build."
        } catch {
            errorMessage = "That session could not be signed out."
        }
    }

    @MainActor
    private func signOutAllOthers() async {
        isWorking = true
        defer { isWorking = false }
        var failures: [String] = []
        for device in otherDevices {
            do {
                try await matrixSession.revokeMatrixDevice(deviceID: device.id)
            } catch {
                failures.append(device.displayName ?? device.id)
            }
        }
        if failures.isEmpty {
            infoMessage = "Signed out of all other sessions."
        } else {
            errorMessage = "Could not sign out: \(failures.joined(separator: ", "))."
        }
        await load()
    }
}
