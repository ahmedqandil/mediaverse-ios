import Foundation
import UIKit
import UserNotifications

struct MatrixHTTPPusherConfiguration: Decodable, Equatable, Sendable {
    let version: Int
    let authority: String
    let kind: String
    let appId: String
    let appDisplayName: String
    let eventFormat: String
    let gatewayUrl: String
    let canonicalReadAuthority: String
    let storesNotificationContent: Bool

    func validated(bundleIdentifier: String) throws -> Self {
        guard
            version == 1,
            authority == "MATRIX_PUSHER_API",
            kind == "http",
            appId == "com.westreem.app",
            appId == bundleIdentifier,
            appDisplayName == "Westreem Vibes",
            eventFormat == "event_id_only",
            canonicalReadAuthority == "MATRIX_RECEIPT",
            !storesNotificationContent,
            let gateway = URL(string: gatewayUrl),
            C.isTrustedBackendURL(gateway)
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        return self
    }
}

struct PushTokenRegistrationResponse: Decodable, Sendable {
    let ok: Bool?
    let matrixPusher: MatrixHTTPPusherConfiguration?
}

struct MatrixPusherRemoval: Decodable, Equatable, Sendable {
    let authority: String
    let pushKey: String
    let appId: String

    func validated() throws -> Self {
        guard
            authority == "MATRIX_PUSHER_API",
            appId == "com.westreem.app",
            pushKey.count >= 32,
            pushKey == pushKey.lowercased(),
            pushKey.allSatisfy(\.isHexDigit)
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        return self
    }
}

struct PushTokenRemovalResponse: Decodable, Sendable {
    let ok: Bool?
    let matrixRemoval: MatrixPusherRemoval
}

@MainActor
protocol MatrixNativePusherManaging: AnyObject {
    func installMatrixPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String,
        deviceDisplayName: String
    ) async throws
    func removeMatrixPusher(_ removal: MatrixPusherRemoval) async throws
}

@MainActor
final class PushNotificationManager {
    static let shared = PushNotificationManager()

    private var latestDeviceToken: String?
    private var isUploadingToken = false
    private var pendingMatrixPusher: MatrixHTTPPusherConfiguration?
    private weak var matrixPusherManager: (any MatrixNativePusherManaging)?
    private let installedTokenKey = "westreem.matrixPusher.installedPushKey"

    private init() {}

    func installMatrixPusherManager(
        _ manager: any MatrixNativePusherManaging
    ) {
        matrixPusherManager = manager
        Task { await uploadLatestTokenIfPossible() }
    }

    func matrixSessionDidBecomeReady() {
        Task { await uploadLatestTokenIfPossible() }
    }

    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                debug("authorization request failed: \(error.localizedDescription)")
                return
            }
            guard granted else {
                debug("authorization denied by user")
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            debug("authorization denied; enable notifications in Settings")
        @unknown default:
            debug("unknown authorization status: \(settings.authorizationStatus.rawValue)")
        }
    }

    func retryRegistrationIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
        await uploadLatestTokenIfPossible()
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        latestDeviceToken = token
        debug("received APNs token prefix=\(String(token.prefix(12)))")
        Task { await uploadLatestTokenIfPossible() }
    }

    func didFailToRegister(error: Error) {
        debug("APNs registration failed: \(error.localizedDescription)")
    }

    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        if let matrixRoute = Self.matrixRoute(from: userInfo) {
            MatrixNativePushRouteStore.shared.stage(matrixRoute)
            NotificationCenter.default.post(
                name: .matrixRoomRouteRequested,
                object: matrixRoute
            )
            return
        }

        IncomingLinkCoordinator.shared.handleNotificationTap(userInfo: userInfo)

        if userInfo["kind"] as? String == "storyPublish" {
            NotificationCenter.default.post(
                name: .storyPublishNotificationTapped,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    static func matrixRoute(from userInfo: [AnyHashable: Any]) -> MatrixNativePushRoute? {
        let stringValue: (String) -> String? = { key in
            if let value = userInfo[key] as? String { return value }
            if let matrix = userInfo["matrix"] as? [String: Any],
               let value = matrix[key] as? String {
                return value
            }
            return nil
        }
        let roomID = stringValue("matrixRoomId")
            ?? stringValue("matrix_room_id")
            ?? stringValue("room_id")
        guard let roomID, roomID.hasPrefix("!"), roomID.contains(":") else { return nil }
        let eventID = stringValue("matrixEventId")
            ?? stringValue("matrix_event_id")
            ?? stringValue("event_id")
        return MatrixNativePushRoute(
            roomID: roomID,
            eventID: eventID?.hasPrefix("$") == true ? eventID : nil
        )
    }

    func consumePendingRoute() -> AppRoute? {
        IncomingLinkCoordinator.shared.consumePendingRoute()
    }

    func consumePendingDeviceActivationCode() -> String? {
        IncomingLinkCoordinator.shared.consumePendingDeviceActivationCode()
    }

    func uploadLatestTokenIfPossible() async {
        guard !isUploadingToken else { return }
        guard let token = latestDeviceToken else { return }
        guard SessionStorage.token != nil else {
            debug("session not ready; will retry APNs token upload later")
            return
        }

        isUploadingToken = true
        defer { isUploadingToken = false }

        do {
            let response = try await APIClient.shared.registerPushToken(
                token: token,
                environment: apnsEnvironment,
                bundleId: bundleIdentifier
            )
            debug("uploaded APNs token for \(apnsEnvironment) topic=\(bundleIdentifier)")
            guard let matrixPusher = response.matrixPusher else {
                pendingMatrixPusher = nil
                debug("Matrix pusher configuration is unavailable")
                return
            }
            let validated = try matrixPusher.validated(
                bundleIdentifier: bundleIdentifier
            )
            pendingMatrixPusher = validated
            try await synchronizeMatrixPusher(
                configuration: validated,
                pushKey: token
            )
        } catch {
            debug("APNs token upload failed: \(error.localizedDescription)")
        }
    }

    func unregisterForSignOut() async {
        guard let token = installedPushKey ?? latestDeviceToken else { return }
        do {
            let response = try await APIClient.shared.unregisterPushToken(
                token: token
            )
            let removal = try response.matrixRemoval.validated()
            try await matrixPusherManager?.removeMatrixPusher(removal)
            installedPushKey = nil
            pendingMatrixPusher = nil
            debug("removed Westreem and Matrix push registrations")
        } catch {
            debug("push token removal failed: \(error.localizedDescription)")
        }
    }

    private func synchronizeMatrixPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String
    ) async throws {
        guard let matrixPusherManager else {
            // Keep the validated configuration pending until the native Matrix
            // session has completed SSO/restoration.
            return
        }
        try await matrixPusherManager.installMatrixPusher(
            configuration: configuration,
            pushKey: pushKey,
            deviceDisplayName: UIDevice.current.name
        )

        if let previous = installedPushKey, previous != pushKey {
            do {
                let response = try await APIClient.shared.unregisterPushToken(
                    token: previous
                )
                try await matrixPusherManager.removeMatrixPusher(
                    try response.matrixRemoval.validated()
                )
            } catch {
                // The new pusher is already authoritative. A stale identifier
                // is harmless at the gateway because its Westreem token row is
                // removed independently on the next authenticated cleanup.
                debug("old Matrix pusher cleanup failed: \(error.localizedDescription)")
            }
        }
        installedPushKey = pushKey
        pendingMatrixPusher = nil
        debug("installed Matrix event_id_only HTTP pusher")
    }

    private var installedPushKey: String? {
        get {
            UserDefaults.standard.string(forKey: installedTokenKey)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: installedTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: installedTokenKey)
            }
        }
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.westreem.app"
    }

    private var apnsEnvironment: String {
        if let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let profileData = try? Data(contentsOf: profileURL),
           let profileText = String(data: profileData, encoding: .isoLatin1),
           let environment = environmentFromProvisioningProfile(profileText) {
            return environment
        }

        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    private func environmentFromProvisioningProfile(_ profileText: String) -> String? {
        guard let keyRange = profileText.range(of: "<key>aps-environment</key>") else { return nil }
        let suffix = profileText[keyRange.upperBound...]
        guard let stringStart = suffix.range(of: "<string>")?.upperBound,
              let stringEnd = suffix[stringStart...].range(of: "</string>")?.lowerBound else { return nil }
        let environment = suffix[stringStart..<stringEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environment.isEmpty ? nil : environment
    }

    private func debug(_ message: String) {
        #if DEBUG
        print("[push] \(message)")
        #endif
    }
}
