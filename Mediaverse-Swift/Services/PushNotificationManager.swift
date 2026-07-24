import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushNotificationManager {
    static let shared = PushNotificationManager()

    private var latestDeviceToken: String?
    private var isUploadingToken = false

    private init() {}

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
        IncomingLinkCoordinator.shared.handleNotificationTap(userInfo: userInfo)

        if userInfo["kind"] as? String == "storyPublish" {
            NotificationCenter.default.post(
                name: .storyPublishNotificationTapped,
                object: nil,
                userInfo: userInfo
            )
        }
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
            try await APIClient.shared.registerPushToken(token: token, environment: apnsEnvironment, bundleId: bundleIdentifier)
            debug("uploaded APNs token for \(apnsEnvironment) topic=\(bundleIdentifier)")
        } catch {
            debug("APNs token upload failed: \(error.localizedDescription)")
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
