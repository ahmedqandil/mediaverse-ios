import SwiftUI

struct DeviceActivationSheet: View {
    let userCode: String
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isActivating = false
    @State private var activationSucceeded = false
    @State private var activatedDeviceName: String?
    @State private var errorMessage: String?

    private var normalizedCode: String {
        userCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    statusIcon

                    VStack(alignment: .leading, spacing: 8) {
                        Text(activationSucceeded ? "Device paired" : "Pair a device")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(C.text)

                        Text(activationSucceeded ? successMessage : "Approve the device showing this code. Only continue if the code matches the screen you are pairing.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(C.textMuted)
                            .lineSpacing(3)
                    }

                    Text(normalizedCode)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(C.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(C.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.9))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Spacer(minLength: 8)

                    Button {
                        if activationSucceeded {
                            close()
                        } else {
                            Task { await activate() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isActivating {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: activationSucceeded ? "checkmark" : "tv")
                            }
                            Text(activationSucceeded ? "Done" : "Approve Device")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(C.watch)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isActivating)

                    if !activationSucceeded {
                        Button("Cancel") { close() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Device Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                        .foregroundStyle(C.watch)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var successMessage: String {
        if let activatedDeviceName, !activatedDeviceName.isEmpty {
            return "\(activatedDeviceName) can now access your WeStreem account."
        }
        return "The device can now access your WeStreem account."
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill((activationSucceeded ? C.watch : C.surfaceAlt).opacity(activationSucceeded ? 0.24 : 1))
                .frame(width: 64, height: 64)
            Image(systemName: activationSucceeded ? "checkmark.seal.fill" : "tv.and.mediabox")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(activationSucceeded ? C.watch : C.text)
        }
    }

    @MainActor
    private func activate() async {
        guard !normalizedCode.isEmpty else { return }
        isActivating = true
        errorMessage = nil
        defer { isActivating = false }

        do {
            let response = try await APIClient.shared.activateDevicePairing(userCode: normalizedCode)
            activatedDeviceName = response.deviceName
            activationSucceeded = true
        } catch {
            errorMessage = activationErrorMessage(for: error)
        }
    }

    private func activationErrorMessage(for error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        switch apiError {
        case .unauthorized:
            return "Sign in before approving a device."
        case .notFound:
            return "That code was not found. Check the code and try again."
        case .http(let status):
            switch status {
            case 403: return "You have reached the paired device limit. Revoke an old device first."
            case 409: return "That code has already been used."
            case 410: return "That code expired. Restart pairing on the TV."
            case 423: return "Too many wrong attempts. Restart pairing on the TV."
            default: return "Could not pair this device. HTTP \(status)."
            }
        default:
            return apiError.localizedDescription
        }
    }

    private func close() {
        onDismiss()
        dismiss()
    }
}

struct PairedDevicesView: View {
    @State private var devices = [PairedDevice]()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var revokingDeviceId: String?
    @State private var devicePendingRevocation: PairedDevice?

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(C.watch)
            } else if devices.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(devices) { device in
                            deviceRow(device)
                                .listRowBackground(C.surface)
                        }
                    } footer: {
                        Text("Revoking a device signs it out the next time it contacts WeStreem.")
                            .foregroundStyle(C.textMuted)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Paired Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(C.watch)
                .disabled(isLoading)
                .accessibilityLabel("Refresh devices")
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.92))
                    .clipShape(Capsule())
                    .padding(.bottom, 16)
            }
        }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: revokeDialogBinding,
            titleVisibility: .visible
        ) {
            if let device = devicePendingRevocation {
                Button("Revoke \(device.deviceName)", role: .destructive) {
                    Task { await revoke(device) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let device = devicePendingRevocation {
                Text("\(device.deviceName) will be signed out the next time it contacts WeStreem.")
            }
        }
        .task { await loadDevices() }
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { devicePendingRevocation != nil },
            set: { isPresented in
                if !isPresented {
                    devicePendingRevocation = nil
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(C.textMuted)
            Text("No paired devices")
                .font(.headline)
                .foregroundStyle(C.text)
            Text("TV and living-room devices you approve will appear here.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(C.watch.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: iconName(for: device.deviceType))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(C.watch)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text(deviceSubtitle(device))
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .lineLimit(2)
            }

            Spacer()

            Button(role: .destructive) {
                devicePendingRevocation = device
            } label: {
                if revokingDeviceId == device.id {
                    ProgressView().tint(.red)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.plain)
            .disabled(revokingDeviceId != nil)
        }
        .padding(.vertical, 8)
    }

    @MainActor
    private func loadDevices() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            devices = try await APIClient.shared.fetchPairedDevices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func revoke(_ device: PairedDevice) async {
        revokingDeviceId = device.id
        errorMessage = nil
        defer { revokingDeviceId = nil }
        do {
            try await APIClient.shared.revokePairedDevice(id: device.id)
            devices.removeAll { $0.id == device.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        let type = displayName(for: device.deviceType)
        if let lastSeenAt = device.lastSeenAt, !lastSeenAt.isEmpty {
            return "\(type) · Last seen \(relativeTime(lastSeenAt))"
        }
        return "\(type) · Paired \(relativeTime(device.createdAt))"
    }

    private func displayName(for type: String) -> String {
        switch type {
        case "apple_tv": return "Apple TV"
        case "android_tv": return "Android TV"
        case "roku": return "Roku"
        case "smart_tv": return "Smart TV"
        default: return "Device"
        }
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "apple_tv", "android_tv", "smart_tv": return "tv"
        case "roku": return "rectangle.connected.to.line.below"
        default: return "display"
        }
    }

    private func relativeTime(_ iso: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: iso) ?? standard.date(from: iso) else { return iso }

        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 14 { return "\(days)d ago" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
