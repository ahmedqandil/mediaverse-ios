import Foundation
import Combine
import CryptoKit
import Security
import UIKit
import UserNotifications

private enum PushRegistrationSecureStore {
    private static let service = "com.westreem.mediaverse.push-registration.v2"
    private static let v3Service = "com.westreem.mediaverse.push-registration.v3"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                return false
            }
        } else if status != errSecSuccess {
            return false
        }
        return self.data(for: account) == data
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        write(Data(value.utf8), account: account)
    }

    static func remove(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    static func v3Data(for account: String) -> Data? {
        data(for: account, service: v3Service)
    }

    @discardableResult
    static func writeV3(_ data: Data, account: String) -> Bool {
        write(data, account: account, service: v3Service)
    }

    static func removeV3(account: String) {
        SecItemDelete(baseQuery(account: account, service: v3Service) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        baseQuery(account: account, service: service)
    }

    private static func data(for account: String, service: String) -> Data? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    @discardableResult
    private static func write(_ data: Data, account: String, service: String) -> Bool {
        let query = baseQuery(account: account, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                return false
            }
        } else if status != errSecSuccess {
            return false
        }
        return self.data(for: account, service: service) == data
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

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
    let ownerProof: MatrixPusherOwnerProof?
    let ownerProofMode: MatrixPusherOwnerProofMode

    private enum CodingKeys: String, CodingKey {
        case version, authority, kind, appId, appDisplayName, eventFormat
        case gatewayUrl, canonicalReadAuthority, storesNotificationContent
        case ownerProof, ownerProofMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        authority = try values.decode(String.self, forKey: .authority)
        kind = try values.decode(String.self, forKey: .kind)
        appId = try values.decode(String.self, forKey: .appId)
        appDisplayName = try values.decode(String.self, forKey: .appDisplayName)
        eventFormat = try values.decode(String.self, forKey: .eventFormat)
        gatewayUrl = try values.decode(String.self, forKey: .gatewayUrl)
        canonicalReadAuthority = try values.decode(
            String.self,
            forKey: .canonicalReadAuthority
        )
        storesNotificationContent = try values.decode(
            Bool.self,
            forKey: .storesNotificationContent
        )
        ownerProof = try values.decodeIfPresent(
            MatrixPusherOwnerProof.self,
            forKey: .ownerProof
        )
        // Old APPLICATION_SERVICE servers omit both fields and therefore
        // remain byte-for-byte on the existing pusher contract.
        ownerProofMode = try values.decodeIfPresent(
            MatrixPusherOwnerProofMode.self,
            forKey: .ownerProofMode
        ) ?? .off
    }

    func validated(expectedAppID: String) throws -> Self {
        guard
            version == 1,
            authority == "MATRIX_PUSHER_API",
            kind == "http",
            ["com.westreem.app", "com.westreem.app.voip"].contains(appId),
            appId == expectedAppID,
            appDisplayName == "Westreem Vibes",
            eventFormat == "event_id_only",
            canonicalReadAuthority == "MATRIX_RECEIPT",
            !storesNotificationContent,
            MatrixPushGatewayContract.accepts(gatewayUrl)
        else {
            throw MatrixSessionFoundationError.unavailable
        }
        _ = try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: ownerProofMode,
            proof: ownerProof
        )
        return self
    }

    func defaultPayloadJSON() throws -> String? {
        try MatrixPusherOwnerProofPolicy.defaultPayload(
            mode: ownerProofMode,
            proof: ownerProof
        )
    }
}

struct PushTokenRegistrationResponse: Decodable, Sendable {
    let ok: Bool?
    let registrationRevision: String?
    let matrixPusher: MatrixHTTPPusherConfiguration?

    func validatedRegistrationRevision() throws -> String? {
        guard let registrationRevision else { return nil }
        return try MatrixPushRegistrationRevision(
            rawValue: registrationRevision
        ).rawValue
    }
}

enum PushTokenRegistrationAttempt: Sendable {
    case registered(PushTokenRegistrationResponse)
    case ownershipConflict(registrationRevision: String)
    case contractUpgradeRequired
    case epochRevoked
}

struct MatrixPusherRemoval: Decodable, Equatable, Sendable {
    let authority: String
    let pushKey: String
    let appId: String

    func validated() throws -> Self {
        guard
            authority == "MATRIX_PUSHER_API",
            ["com.westreem.app", "com.westreem.app.voip"].contains(appId),
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

enum PushTokenRemovalAttempt: Sendable {
    case removed(PushTokenRemovalResponse)
    case ownershipConflict(registrationRevision: String)
    case contractUpgradeRequired
}

@MainActor
protocol MatrixNativePusherManaging: AnyObject {
    func installMatrixPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String,
        deviceDisplayName: String
    ) async throws
    func removeMatrixPusher(_ removal: MatrixPusherRemoval) async throws
    func installOpaqueMatrixPusher(
        configuration: MatrixPushRegistrationV3Pusher,
        deviceDisplayName: String
    ) async throws
    func removeOpaqueMatrixPusher(pushKey: MatrixOpaquePushKey, appID: String) async throws
    func observeMatrixPushers(
        appID: String,
        rawPushKey: String?,
        opaquePushKey: MatrixOpaquePushKey
    ) async throws -> MatrixPusherObservation
}

@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    private struct UploadTaskHandle {
        let id: UUID
        let lease: MatrixPushRegistrationFence.Lease
        let task: Task<Void, Never>
    }

    private struct StoredRegistrationRevision: Codable, Equatable {
        let tokenDigest: String
        let registrationEpoch: String
        let revision: String
    }

    private struct StoredPushRegistrationHandle: Codable, Equatable {
        let token: String
        let appID: String
        let registrationEpoch: String
        let revocationCapability: String
        var registrationRevision: String?
    }

    private struct StoredV3Predecessor: Codable, Equatable {
        let ownerUserID: String
        let providerToken: String
        let appID: String
        let platform: String
        let environment: String
        let registrationEpoch: String
        let revocationCapability: String
        var registrationRevision: String?
        let matrixPushKey: String?
    }

    private struct StoredV3PushRegistration: Codable, Equatable {
        let version: Int
        let ownerUserID: String
        let providerToken: String
        let matrixPushKey: String
        let appID: String
        let platform: String
        let environment: String
        let registrationEpoch: String
        let revocationCapability: String
        var registrationRevision: String?
        var phase: MatrixPushRegistrationV3Phase
        var serverState: MatrixPushRegistrationV3State?
        var rawRetireAt: String?
        var predecessor: StoredV3Predecessor?
    }

    private struct StoredV3Registry: Codable, Equatable {
        let version: Int
        var active: StoredV3PushRegistration?
        var cleanup: [StoredV3PushRegistration]
    }

    private enum RemovalContext {
        case activeRegistration(
            token: String,
            appID: String,
            sessionToken: String,
            lease: MatrixPushRegistrationFence.Lease
        )
        case signOut(sessionToken: String)
    }

    private var latestDeviceToken: String?
    private var latestVoIPToken: String?
    private var pendingMatrixPusher: MatrixHTTPPusherConfiguration?
    private var pendingVoIPMatrixPusher: MatrixHTTPPusherConfiguration?
    private weak var matrixPusherManager: (any MatrixNativePusherManaging)?
    private let installedTokenKey = "westreem.matrixPusher.installedPushKey"
    private let installedVoIPTokenKey = "westreem.matrixPusher.installedVoIPPushKey"
    private let ordinaryRevisionKey = "westreem.matrixPusher.registrationRevision.v2"
    private let voIPRevisionKey = "westreem.matrixPusher.voipRegistrationRevision.v2"
    private let ordinaryEpochKey = "westreem.matrixPusher.registrationEpoch.v2"
    private let voIPEpochKey = "westreem.matrixPusher.voipRegistrationEpoch.v2"
    private let ordinaryRevocationCapabilityKey =
        "westreem.matrixPusher.revocationCapability.v2"
    private let voIPRevocationCapabilityKey =
        "westreem.matrixPusher.voipRevocationCapability.v2"
    private let activeRegistrationHandlesKey =
        "westreem.matrixPusher.activeRegistrationHandles.v2"
    private let cleanupQueueKey = "westreem.matrixPusher.cleanupQueue.v2"
    private var registrationFence = MatrixPushRegistrationFence()
    private var ordinaryUploadTask: UploadTaskHandle?
    private var voIPUploadTask: UploadTaskHandle?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var voIPRetryTask: Task<Void, Never>?
    private var voIPRetryAttempt = 0
    private var cleanupDrainInProgress = false
    private var activeWestreemUserID: String?

    @Published private(set) var ordinaryPushSetupStatus: MatrixPushSetupStatus = .finishingSetup
    @Published private(set) var voIPPushSetupStatus: MatrixPushSetupStatus = .finishingSetup

    private init() {}

    func registerNotificationCategories() {
        let identifiers = ["MATRIX_MESSAGE", "MATRIX_INVITE", "MATRIX_CALL", "MATRIX_LIVE"]
        let categories = Set(identifiers.map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: [])
        })
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func installMatrixPusherManager(
        _ manager: any MatrixNativePusherManaging
    ) {
        matrixPusherManager = manager
        registrationFence.preserveAcrossReadinessChange()
        Task {
            await uploadLatestTokenIfPossible()
            await uploadLatestVoIPTokenIfPossible()
        }
    }

    func matrixSessionDidBecomeReady() {
        registrationFence.preserveAcrossReadinessChange()
        Task {
            await drainV3CleanupRegistries()
            await drainPushRegistrationCleanupQueue()
            await uploadLatestTokenIfPossible()
            await uploadLatestVoIPTokenIfPossible()
        }
    }

    /// A successful full sign-in is the only client event that rotates epochs.
    /// Token refresh and app restoration deliberately reuse them so sign-out
    /// always tombstones the epoch that owns the active server row.
    func westreemDidStartNewAuthenticatedSession(westreemUserID: String) async {
        registrationFence.openSession()
        cancelRetry()
        cancelVoIPRetry()
        let uploads = [ordinaryUploadTask?.task, voIPUploadTask?.task].compactMap { $0 }
        uploads.forEach { $0.cancel() }
        for upload in uploads { await upload.value }
        ordinaryUploadTask = nil
        voIPUploadTask = nil
        // v3 account transfer is privacy-first: retain A's durable proof until
        // B's PREPARE atomically disables A. Never eagerly delete A merely
        // because the local Westreem bearer changed.
        activeWestreemUserID = westreemUserID
        pendingMatrixPusher = nil
        pendingVoIPMatrixPusher = nil
        ordinaryPushSetupStatus = .finishingSetup
        voIPPushSetupStatus = .finishingSetup
        await uploadLatestTokenIfPossible()
        await uploadLatestVoIPTokenIfPossible()
    }

    func westreemDidRestoreAuthenticatedSession(westreemUserID: String) async {
        // PushKit and the ordinary APNs delegate can race ahead of restored
        // authentication. Drain those owner-less uploads before opening the
        // restored account fence, otherwise the retained VoIP credential can
        // be mistaken for an already-reconciled registration.
        cancelRetry()
        cancelVoIPRetry()
        let uploads = [ordinaryUploadTask?.task, voIPUploadTask?.task].compactMap { $0 }
        uploads.forEach { $0.cancel() }
        for upload in uploads { await upload.value }
        ordinaryUploadTask = nil
        voIPUploadTask = nil
        activeWestreemUserID = westreemUserID
        registrationFence.openSession()
        await drainV3CleanupRegistries()
        await drainPushRegistrationCleanupQueue()
        await uploadLatestTokenIfPossible()
        await uploadLatestVoIPTokenIfPossible()
    }

    /// A refreshed bearer remains the same durable app/account session. Keep
    /// the existing epochs and only invalidate in-flight request leases before
    /// reconciling with the new credential.
    func westreemSessionDidRefresh() {
        registrationFence.openSession()
        Task {
            await drainPushRegistrationCleanupQueue()
            await uploadLatestTokenIfPossible()
            await uploadLatestVoIPTokenIfPossible()
        }
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

    func retryRegistrationIfAuthorized(
        reconcileStoredTokens: Bool = true
    ) async {
        // PushKit is independent of ordinary notification authorization. A
        // retained VoIP credential must be replayed and reconciled even when
        // the user denied alert/badge/sound permission.
        if reconcileStoredTokens,
           SessionStorage.token != nil,
           activeWestreemUserID != nil {
            await uploadLatestTokenIfPossible()
            await uploadLatestVoIPTokenIfPossible()
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        if latestDeviceToken != token {
            if let previous = latestDeviceToken {
                enqueueKnownRegistration(token: previous, appID: bundleIdentifier)
            }
            registrationFence.invalidateRegistrationContext()
            cancelRetry()
        }
        latestDeviceToken = token
        // Device tokens are credentials. Never expose even a stable prefix in
        // diagnostic output; successful registration is enough telemetry.
        debug("received APNs device token")
        Task { await uploadLatestTokenIfPossible() }
    }

    func didRegisterVoIP(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        if latestVoIPToken != token {
            if let previous = latestVoIPToken {
                enqueueKnownRegistration(token: previous, appID: "com.westreem.app.voip")
            }
            registrationFence.invalidateRegistrationContext()
            cancelVoIPRetry()
        }
        latestVoIPToken = token
        debug("received APNs VoIP token")
        Task { await uploadLatestVoIPTokenIfPossible() }
    }

    func didInvalidateVoIPToken() {
        let appID = "com.westreem.app.voip"
        let invalidatedToken = installedVoIPPushKey ?? latestVoIPToken
        registrationFence.invalidateRegistrationContext()
        cancelVoIPRetry()
        if let invalidatedToken {
            enqueueKnownRegistration(token: invalidatedToken, appID: appID)
        }
        enqueueActiveV3RegistrationForCleanup(appID: appID)
        latestVoIPToken = nil
        installedVoIPPushKey = nil
        pendingVoIPMatrixPusher = nil
        voIPPushSetupStatus = .finishingSetup

        let invalidatedUpload = voIPUploadTask
        invalidatedUpload?.task.cancel()
        voIPUploadTask = nil
        Task { [weak self] in
            await invalidatedUpload?.task.value
            guard let self else { return }
            await self.drainV3CleanupRegistries()
            await self.drainPushRegistrationCleanupQueue()
        }
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

    /// Remove stale notification-centre entries only after Matrix has accepted
    /// the room receipt. The Matrix unread count remains badge authority; this
    /// deliberately does not guess at, or locally decrement, the app badge.
    func clearDeliveredMatrixNotifications(roomID: String) async {
        guard Self.isCanonicalMatrixIdentifier(roomID, sigil: "!") else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered.compactMap { notification -> String? in
            guard Self.matrixRoute(
                from: notification.request.content.userInfo
            )?.roomID == roomID else { return nil }
            return notification.request.identifier
        }
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
        guard let roomID, isCanonicalMatrixIdentifier(roomID, sigil: "!") else { return nil }
        let eventID = stringValue("matrixEventId")
            ?? stringValue("matrix_event_id")
            ?? stringValue("event_id")
        return MatrixNativePushRoute(
            roomID: roomID,
            eventID: eventID.flatMap {
                isCanonicalMatrixIdentifier($0, sigil: "$") ? $0 : nil
            }
        )
    }

    private static func isCanonicalMatrixIdentifier(
        _ value: String,
        sigil: Character
    ) -> Bool {
        guard value.count >= 2, value.count <= 512, value.first == sigil,
              (sigil == "$" || value.contains(":")),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { return false }
        return true
    }

    func consumePendingRoute() -> AppRoute? {
        IncomingLinkCoordinator.shared.consumePendingRoute()
    }

    func consumePendingDeviceActivationCode() -> String? {
        IncomingLinkCoordinator.shared.consumePendingDeviceActivationCode()
    }

    func uploadLatestTokenIfPossible() async {
        if let handle = ordinaryUploadTask {
            await handle.task.value
            if ordinaryUploadTask?.id == handle.id {
                ordinaryUploadTask = nil
            }
            if !registrationFence.accepts(handle.lease) {
                await uploadLatestTokenIfPossible()
            }
            return
        }
        guard let lease = registrationFence.beginRegistration() else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLatestTokenUpload(lease: lease)
        }
        ordinaryUploadTask = UploadTaskHandle(id: id, lease: lease, task: task)
        await task.value
        if ordinaryUploadTask?.id == id {
            ordinaryUploadTask = nil
        }
    }

    private func performLatestTokenUpload(
        lease: MatrixPushRegistrationFence.Lease
    ) async {
        guard let token = latestDeviceToken else { return }
        guard let sessionToken = SessionStorage.token else {
            debug("session not ready; will retry APNs token upload later")
            return
        }
        let appID = bundleIdentifier
        guard let environment = apnsEnvironment else {
            setV3Status(.actionRequired, appID: appID)
            debug("APNs environment is not valid for push registration v3")
            return
        }

        do {
            try Task.checkCancellation()
            setV3Status(.finishingSetup, appID: appID)
            try await reconcileOpaquePushRegistration(
                token: token,
                environment: environment,
                appID: appID,
                deviceDisplayName: UIDevice.current.name,
                sessionToken: sessionToken,
                lease: lease
            )
            cancelRetry()
            debug("installed opaque Matrix event_id_only HTTP pusher")
        } catch is CancellationError {
            return
        } catch let error as MatrixPushRegistrationV3TransportError {
            switch error {
            case .permanentContractFailure, .credentialExpired, .actionRequired:
                setV3Status(.actionRequired, appID: appID)
            case .deliveryLeaseActive:
                setV3Status(.finishingSetup, appID: appID)
                scheduleRetry()
            case .authoritativeRefreshRequired, .retryable:
                setV3Status(.retryingOffline, appID: appID)
                scheduleRetry()
            }
            debug("Matrix push setup paused: \(error.localizedDescription)")
        } catch {
            setV3Status(.retryingOffline, appID: appID)
            debug("Matrix push setup will retry: \(error.localizedDescription)")
            scheduleRetry()
        }
    }

    func uploadLatestVoIPTokenIfPossible() async {
        if let handle = voIPUploadTask {
            await handle.task.value
            if voIPUploadTask?.id == handle.id {
                voIPUploadTask = nil
            }
            if !registrationFence.accepts(handle.lease) {
                await uploadLatestVoIPTokenIfPossible()
            }
            return
        }
        guard let lease = registrationFence.beginRegistration() else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLatestVoIPTokenUpload(lease: lease)
        }
        voIPUploadTask = UploadTaskHandle(id: id, lease: lease, task: task)
        await task.value
        if voIPUploadTask?.id == id {
            voIPUploadTask = nil
        }
    }

    private func setV3Status(_ status: MatrixPushSetupStatus, appID: String) {
        if appID == "com.westreem.app.voip" {
            voIPPushSetupStatus = status
        } else if appID == bundleIdentifier {
            ordinaryPushSetupStatus = status
        }
    }

    private enum MatrixPushReconciliationUnavailableStage: String {
        case confirmationObservation = "confirmation_observation"
        case rawRemovalContract = "raw_removal_contract"
        case rawRemovalObservation = "raw_removal_observation"
        case finalProjection = "final_projection"
    }

    private enum MatrixPushReconciliationStage: String {
        case prepared
        case resumed
        case pusherInstallStarted = "pusher_install_started"
        case pusherInstalled = "pusher_installed"
        case observationDual = "observation_dual"
        case observationOpaqueOnly = "observation_opaque_only"
        case observationRawOnly = "observation_raw_only"
        case observationEmpty = "observation_empty"
        case dualMissingRawRecovery = "dual_missing_raw_recovery"
        case confirmStarted = "confirm_started"
        case confirmed
        case rawRemovalStarted = "raw_removal_started"
        case rawRemoved = "raw_removed"
        case retireRawStarted = "retire_raw_started"
        case retired
        case ready
    }

    private func reconciliationUnavailable(
        _ stage: MatrixPushReconciliationUnavailableStage,
        appID: String
    ) -> MatrixSessionFoundationError {
        let topic = appID == "com.westreem.app.voip" ? "voip" : "ordinary"
        debug("push reconciliation unavailable stage=\(stage.rawValue) topic=\(topic)")
        return .unavailable
    }

    private func traceReconciliation(
        _ stage: MatrixPushReconciliationStage,
        appID: String
    ) {
        let topic = appID == "com.westreem.app.voip" ? "voip" : "ordinary"
        debug("push reconciliation stage=\(stage.rawValue) topic=\(topic)")
    }

    private func traceObservation(
        _ observation: MatrixPusherObservation,
        appID: String
    ) {
        let stage: MatrixPushReconciliationStage
        switch (observation.opaquePresent, observation.rawPresent) {
        case (true, true): stage = .observationDual
        case (true, false): stage = .observationOpaqueOnly
        case (false, true): stage = .observationRawOnly
        case (false, false): stage = .observationEmpty
        }
        traceReconciliation(stage, appID: appID)
    }

    private func persistV3Projection(
        _ response: MatrixPushRegistrationV3Response,
        phase: MatrixPushRegistrationV3Phase,
        record: inout StoredV3PushRegistration
    ) throws {
        record.registrationRevision = response.registrationRevision
        record.serverState = response.registrationState
        record.rawRetireAt = response.rawRetireAt
        record.phase = phase
        try updateV3Record(record)
    }

    private func reconcileOpaquePushRegistration(
        token: String,
        environment: String,
        appID: String,
        deviceDisplayName: String,
        sessionToken: String,
        lease: MatrixPushRegistrationFence.Lease
    ) async throws {
        guard let ownerUserID = activeWestreemUserID, !ownerUserID.isEmpty else {
            debug("push prerequisite missing: authenticated owner")
            throw MatrixSessionFoundationError.unavailable
        }
        guard let matrixPusherManager else {
            debug("push prerequisite missing: Matrix pusher manager")
            throw MatrixSessionFoundationError.unavailable
        }
        var record = try v3RecordForCurrentContext(
            ownerUserID: ownerUserID,
            providerToken: token,
            appID: appID,
            environment: environment
        )
        let opaqueKey = try MatrixOpaquePushKey(rawValue: record.matrixPushKey)

        func contextIsCurrent() -> Bool {
            registrationContextIsCurrent(
                token: token,
                appID: appID,
                sessionToken: sessionToken,
                lease: lease
            ) && activeWestreemUserID == ownerUserID
        }
        guard contextIsCurrent() else { throw CancellationError() }

        var projection: MatrixPushRegistrationV3Response
        if record.phase == .generated {
            var expectedRevision = record.predecessor == nil
                ? record.registrationRevision : nil
            var predecessorRevision = record.predecessor?.registrationRevision
            var preparedProjection: MatrixPushRegistrationV3Response?
            var revisionConflictAttempts = 0
            var deliveryLeaseWaitAttempts = 0
            while preparedProjection == nil {
                do {
                    preparedProjection = try await APIClient.shared.mutatePushRegistrationV3(
                        command: .prepare,
                        token: token,
                        environment: environment,
                        bundleId: appID,
                        matrixPushKey: opaqueKey,
                        registrationEpoch: record.registrationEpoch,
                        revocationCapability: record.revocationCapability,
                        expectedRevision: expectedRevision,
                        predecessorRegistrationEpoch: record.predecessor?.registrationEpoch,
                        predecessorRevocationCapability: record.predecessor?.revocationCapability,
                        predecessorRevision: predecessorRevision
                    )
                    break
                } catch let MatrixPushRegistrationV3TransportError.authoritativeRefreshRequired(
                    registrationRevision
                ) {
                    guard revisionConflictAttempts
                            < MatrixPushRegistrationRetryPolicy.maximumConflictRetries,
                          contextIsCurrent()
                    else { throw MatrixPushRegistrationV3TransportError.actionRequired }
                    revisionConflictAttempts += 1
                    if record.predecessor != nil {
                        predecessorRevision = registrationRevision
                        record.predecessor?.registrationRevision = registrationRevision
                    } else {
                        expectedRevision = registrationRevision
                        record.registrationRevision = registrationRevision
                    }
                    // Persist the authoritative revision before retrying. If
                    // the process dies here, neither a same-owner migration nor
                    // an A→B handoff can forget the CAS/predecessor fence.
                    try updateV3Record(record)
                } catch let MatrixPushRegistrationV3TransportError.deliveryLeaseActive(
                    retryAfterMilliseconds
                ) {
                    // A server lease may legitimately span 30 seconds. Wait
                    // once in-call, independently of CAS retries; if it is
                    // still active, hand off to the durable retry scheduler
                    // while the UI truthfully remains "Finishing setup".
                    guard deliveryLeaseWaitAttempts
                            < MatrixPushDeliveryLeaseRetryPolicy.maximumInCallWaits,
                          contextIsCurrent()
                    else {
                        throw MatrixPushRegistrationV3TransportError.deliveryLeaseActive(
                            retryAfterMilliseconds: retryAfterMilliseconds
                        )
                    }
                    deliveryLeaseWaitAttempts += 1
                    try await Task.sleep(
                        for: .milliseconds(retryAfterMilliseconds)
                    )
                    guard contextIsCurrent() else { throw CancellationError() }
                }
            }
            guard let preparedProjection else {
                throw MatrixPushRegistrationV3TransportError.actionRequired
            }
            projection = preparedProjection
            guard contextIsCurrent() else { throw CancellationError() }
            try persistV3Projection(projection, phase: .prepared, record: &record)
            traceReconciliation(.prepared, appID: appID)
        } else {
            projection = try await APIClient.shared.fetchPushRegistrationV3(
                matrixPushKey: opaqueKey,
                environment: environment,
                bundleId: appID,
                expectedRawPushKey: token
            )
            guard contextIsCurrent() else { throw CancellationError() }
            try persistV3Projection(projection, phase: record.phase, record: &record)
            traceReconciliation(.resumed, appID: appID)
        }

        if projection.registrationState == .revoked {
            var registry = try loadV3Registry(appID: appID, environment: environment)
            if !registry.cleanup.contains(record) { registry.cleanup.append(record) }
            let replacement = try makeV3Record(
                ownerUserID: ownerUserID,
                providerToken: token,
                appID: appID,
                environment: environment,
                expectedRevision: projection.registrationRevision,
                predecessor: nil
            )
            registry.active = replacement
            try persistV3Registry(registry, appID: appID, environment: environment)
            // The next bounded retry performs PREPARE with a fresh key, epoch
            // and capability. The revoked generation remains tombstoned and
            // cannot delete or resurrect this replacement.
            throw MatrixPushRegistrationV3TransportError.authoritativeRefreshRequired(
                registrationRevision: projection.registrationRevision
            )
        }

        guard projection.registrationState != .rawActiveV2 else {
            throw MatrixPushRegistrationV3TransportError.permanentContractFailure
        }
        _ = try projection.matrixPusher.validated(
            expectedAppID: appID,
            expectedKey: opaqueKey
        )
        traceReconciliation(.pusherInstallStarted, appID: appID)
        try await matrixPusherManager.installOpaqueMatrixPusher(
            configuration: projection.matrixPusher,
            deviceDisplayName: deviceDisplayName
        )
        guard contextIsCurrent() else { throw CancellationError() }
        traceReconciliation(.pusherInstalled, appID: appID)
        record.phase = .opaqueInstalled
        try updateV3Record(record)

        var observation = try await matrixPusherManager.observeMatrixPushers(
            appID: appID,
            rawPushKey: token,
            opaquePushKey: opaqueKey
        )
        guard contextIsCurrent() else { throw CancellationError() }
        traceObservation(observation, appID: appID)

        if projection.registrationState == .opaquePreparedNoRaw,
           observation.rawPresent {
            // Returning account B may still have B's own legacy raw pusher.
            // Delete only the exact current Matrix account/app/token entry;
            // A's pusher lives in A's Matrix namespace and is unreachable.
            try await matrixPusherManager.removeMatrixPusher(
                MatrixPusherRemoval(
                    authority: "MATRIX_PUSHER_API",
                    pushKey: token,
                    appId: appID
                )
            )
            guard contextIsCurrent() else { throw CancellationError() }
            observation = try await matrixPusherManager.observeMatrixPushers(
                appID: appID,
                rawPushKey: token,
                opaquePushKey: opaqueKey
            )
            traceObservation(observation, appID: appID)
        }

        if projection.registrationState == .dualPrepared
            || projection.registrationState == .opaquePreparedNoRaw {
            guard let confirmationMode = MatrixOpaquePushMigrationPolicy.confirmationMode(
                state: projection.registrationState,
                observed: observation
            ) else {
                throw reconciliationUnavailable(.confirmationObservation, appID: appID)
            }
            if confirmationMode == .dualPreparedMissingRawRecovery {
                traceReconciliation(.dualMissingRawRecovery, appID: appID)
            }
            traceReconciliation(.confirmStarted, appID: appID)
            projection = try await APIClient.shared.mutatePushRegistrationV3(
                command: .confirm,
                token: token,
                environment: environment,
                bundleId: appID,
                matrixPushKey: opaqueKey,
                registrationEpoch: record.registrationEpoch,
                revocationCapability: record.revocationCapability,
                expectedRevision: projection.registrationRevision,
                matrixPusherObservation: observation
            )
            guard contextIsCurrent() else { throw CancellationError() }
            try persistV3Projection(projection, phase: .confirmed, record: &record)
            traceReconciliation(.confirmed, appID: appID)
        }

        if projection.registrationState == .opaqueConfirmedRawActive {
            guard let rawRemoval = projection.rawMatrixRemoval,
                  rawRemoval.pushKey == token,
                  rawRemoval.appId == appID
            else {
                throw reconciliationUnavailable(.rawRemovalContract, appID: appID)
            }
            traceReconciliation(.rawRemovalStarted, appID: appID)
            try await matrixPusherManager.removeMatrixPusher(
                MatrixPusherRemoval(
                    authority: rawRemoval.authority,
                    pushKey: rawRemoval.pushKey,
                    appId: rawRemoval.appId
                )
            )
            guard contextIsCurrent() else { throw CancellationError() }
            traceReconciliation(.rawRemoved, appID: appID)
            record.phase = .rawRemoved
            try updateV3Record(record)
            observation = try await matrixPusherManager.observeMatrixPushers(
                appID: appID,
                rawPushKey: token,
                opaquePushKey: opaqueKey
            )
            traceObservation(observation, appID: appID)
            guard MatrixOpaquePushMigrationPolicy.canRetireRaw(observed: observation),
                  contextIsCurrent()
            else {
                throw reconciliationUnavailable(.rawRemovalObservation, appID: appID)
            }
            traceReconciliation(.retireRawStarted, appID: appID)
            projection = try await APIClient.shared.mutatePushRegistrationV3(
                command: .retireRaw,
                token: token,
                environment: environment,
                bundleId: appID,
                matrixPushKey: opaqueKey,
                registrationEpoch: record.registrationEpoch,
                revocationCapability: record.revocationCapability,
                expectedRevision: projection.registrationRevision,
                matrixPusherObservation: observation
            )
            guard contextIsCurrent() else { throw CancellationError() }
            try persistV3Projection(projection, phase: .active, record: &record)
            traceReconciliation(.retired, appID: appID)
        }

        if (projection.registrationState == .rawGrace
                || projection.registrationState == .opaqueActiveRawRetired),
           observation.rawPresent {
            // RAW_GRACE is gateway-only grace after RETIRE_RAW. If a crash or
            // external client reintroduced this current identity's exact raw
            // pusher, remove it again and prove absence. Never reuse the
            // server rawMatrixRemoval authority outside its frozen state.
            try await matrixPusherManager.removeMatrixPusher(
                MatrixPusherRemoval(
                    authority: "MATRIX_PUSHER_API",
                    pushKey: token,
                    appId: appID
                )
            )
            guard contextIsCurrent() else { throw CancellationError() }
            observation = try await matrixPusherManager.observeMatrixPushers(
                appID: appID,
                rawPushKey: token,
                opaquePushKey: opaqueKey
            )
            traceObservation(observation, appID: appID)
        }

        guard projection.registrationState == .opaqueActiveRawRetired
                || projection.registrationState == .rawGrace,
              !projection.pushSetupPending,
              observation.opaquePresent,
              !observation.rawPresent
        else {
            throw reconciliationUnavailable(.finalProjection, appID: appID)
        }
        record.phase = .active
        try updateV3Record(record)
        setV3Status(.ready, appID: appID)
        traceReconciliation(.ready, appID: appID)
        await drainV3CleanupRegistries()
    }

    private func enqueueActiveV3RegistrationsForCleanup() {
        for appID in [bundleIdentifier, "com.westreem.app.voip"] {
            enqueueActiveV3RegistrationForCleanup(appID: appID)
        }
    }

    private func enqueueActiveV3RegistrationForCleanup(appID: String) {
        for environment in ["sandbox", "production"] {
            guard var registry = try? loadV3Registry(
                appID: appID,
                environment: environment
            ), var active = registry.active else { continue }
            active.phase = .cleanupPending
            if !registry.cleanup.contains(active) { registry.cleanup.append(active) }
            registry.active = nil
            try? persistV3Registry(
                registry,
                appID: appID,
                environment: environment
            )
            setV3Status(.cleanupPending, appID: appID)
        }
    }

    private func drainV3CleanupRegistries() async {
        for environment in ["sandbox", "production"] {
            for appID in [bundleIdentifier, "com.westreem.app.voip"] {
                guard var registry = try? loadV3Registry(
                    appID: appID,
                    environment: environment
                ), !registry.cleanup.isEmpty else { continue }
                var retained = [StoredV3PushRegistration]()
                for record in registry.cleanup {
                    guard let revision = record.registrationRevision,
                          let opaqueKey = try? MatrixOpaquePushKey(
                              rawValue: record.matrixPushKey
                          )
                    else {
                        retained.append(record)
                        continue
                    }
                    do {
                        let response = try await APIClient.shared.unregisterPushTokenV3(
                            token: record.providerToken,
                            bundleId: record.appID,
                            matrixPushKey: opaqueKey,
                            environment: record.environment,
                            registrationEpoch: record.registrationEpoch,
                            revocationCapability: record.revocationCapability,
                            expectedRevision: revision
                        )
                        guard response.registrationState == .revoked else {
                            retained.append(record)
                            continue
                        }
                        // REVOKED is the server-authoritative provider-slot
                        // release. Only now may this A generation leave the
                        // durable cleanup registry; a later B registration
                        // starts with a fresh opaque key and no predecessor.
                        // A Matrix client may delete only a pusher owned by the
                        // same Westreem identity. During A→B cleanup the server
                        // tombstone is sufficient; B never operates on A's
                        // Matrix pusher namespace.
                        if record.ownerUserID == activeWestreemUserID {
                            try? await matrixPusherManager?.removeOpaqueMatrixPusher(
                                pushKey: opaqueKey,
                                appID: record.appID
                            )
                        }
                    } catch {
                        retained.append(record)
                    }
                }
                registry.cleanup = retained
                try? persistV3Registry(
                    registry,
                    appID: appID,
                    environment: environment
                )
                if !retained.isEmpty { setV3Status(.cleanupPending, appID: appID) }
            }
        }
    }

    private func performLatestVoIPTokenUpload(
        lease: MatrixPushRegistrationFence.Lease
    ) async {
        guard let token = latestVoIPToken,
              let sessionToken = SessionStorage.token
        else { return }
        let appID = "com.westreem.app.voip"
        guard let environment = apnsEnvironment else {
            setV3Status(.actionRequired, appID: appID)
            debug("APNs environment is not valid for push registration v3")
            return
        }
        do {
            try Task.checkCancellation()
            setV3Status(.finishingSetup, appID: appID)
            try await reconcileOpaquePushRegistration(
                token: token,
                environment: environment,
                appID: appID,
                deviceDisplayName: "\(UIDevice.current.name) Calls",
                sessionToken: sessionToken,
                lease: lease
            )
            cancelVoIPRetry()
            debug("installed opaque Matrix VoIP event_id_only HTTP pusher")
        } catch is CancellationError {
            return
        } catch let error as MatrixPushRegistrationV3TransportError {
            switch error {
            case .permanentContractFailure, .credentialExpired, .actionRequired:
                setV3Status(.actionRequired, appID: appID)
            case .deliveryLeaseActive:
                setV3Status(.finishingSetup, appID: appID)
                scheduleVoIPRetry()
            case .authoritativeRefreshRequired, .retryable:
                setV3Status(.retryingOffline, appID: appID)
                scheduleVoIPRetry()
            }
            debug("Matrix VoIP push setup paused: \(error.localizedDescription)")
        } catch {
            setV3Status(.retryingOffline, appID: appID)
            debug("Matrix VoIP push setup will retry: \(error.localizedDescription)")
            scheduleVoIPRetry()
        }
    }

    func unregisterForSignOut() async {
        registrationFence.beginSignOut()
        cancelRetry()
        cancelVoIPRetry()
        let uploads = [ordinaryUploadTask?.task, voIPUploadTask?.task].compactMap { $0 }
        uploads.forEach { $0.cancel() }
        for upload in uploads {
            await upload.value
        }
        ordinaryUploadTask = nil
        voIPUploadTask = nil
        guard registrationFence.mayDeleteRegistration(pendingUploadCount: 0) else {
            return
        }
        enqueueActiveV3RegistrationsForCleanup()
        await drainV3CleanupRegistries()
        let signOutSessionToken = SessionStorage.token
        let registrations = [
            (installedPushKey ?? latestDeviceToken, "com.westreem.app"),
            (installedVoIPPushKey ?? latestVoIPToken, "com.westreem.app.voip"),
        ]
        for (token, appID) in registrations {
            guard let token else { continue }
            enqueueKnownRegistration(token: token, appID: appID)
            let localRemoval = MatrixPusherRemoval(
                authority: "MATRIX_PUSHER_API",
                pushKey: token.lowercased(),
                appId: appID
            )
            try? await matrixPusherManager?.removeMatrixPusher(localRemoval)
        }
        _ = signOutSessionToken
        await drainPushRegistrationCleanupQueue()
        clearRegistrationEpoch(appID: bundleIdentifier)
        clearRegistrationEpoch(appID: "com.westreem.app.voip")
        clearRevocationCapability(appID: bundleIdentifier)
        clearRevocationCapability(appID: "com.westreem.app.voip")
        clearRegistrationRevision(appID: bundleIdentifier)
        clearRegistrationRevision(appID: "com.westreem.app.voip")
        latestDeviceToken = nil
        latestVoIPToken = nil
        installedPushKey = nil
        installedVoIPPushKey = nil
        pendingMatrixPusher = nil
        pendingVoIPMatrixPusher = nil
        activeWestreemUserID = nil
    }

    /// A server-declared expired Westreem session may arrive after APIClient
    /// has already removed the bearer. Persist cleanup capability handles
    /// first, then use the credential-free v2 DELETE path. Offline failures
    /// remain queued for the next restoration/foreground reconciliation.
    func handleExpiredWestreemSession() async {
        registrationFence.beginSignOut()
        cancelRetry()
        cancelVoIPRetry()
        let uploads = [ordinaryUploadTask?.task, voIPUploadTask?.task].compactMap { $0 }
        uploads.forEach { $0.cancel() }
        for upload in uploads { await upload.value }
        ordinaryUploadTask = nil
        voIPUploadTask = nil
        enqueueActiveV3RegistrationsForCleanup()
        await drainV3CleanupRegistries()
        enqueueAllActiveRegistrationHandlesForCleanup()
        if let token = installedPushKey ?? latestDeviceToken {
            enqueueKnownRegistration(token: token, appID: bundleIdentifier)
        }
        if let token = installedVoIPPushKey ?? latestVoIPToken {
            enqueueKnownRegistration(token: token, appID: "com.westreem.app.voip")
        }
        await drainPushRegistrationCleanupQueue()
        latestDeviceToken = nil
        latestVoIPToken = nil
        installedPushKey = nil
        installedVoIPPushKey = nil
        pendingMatrixPusher = nil
        pendingVoIPMatrixPusher = nil
        clearRegistrationEpoch(appID: bundleIdentifier)
        clearRegistrationEpoch(appID: "com.westreem.app.voip")
        clearRevocationCapability(appID: bundleIdentifier)
        clearRevocationCapability(appID: "com.westreem.app.voip")
        clearRegistrationRevision(appID: bundleIdentifier)
        clearRegistrationRevision(appID: "com.westreem.app.voip")
        activeWestreemUserID = nil
    }

    private func registerPushTokenWithCAS(
        token: String,
        environment: String,
        appID: String,
        sessionToken: String,
        lease: MatrixPushRegistrationFence.Lease
    ) async throws -> PushTokenRegistrationResponse {
        let epoch = try registrationEpoch(appID: appID)
        let revocationCapability = try registrationRevocationCapability(appID: appID)
        var expectedRevision = storedRegistrationRevision(
            token: token,
            appID: appID,
            registrationEpoch: epoch
        )
        try persistActiveRegistrationHandle(
            StoredPushRegistrationHandle(
                token: token,
                appID: appID,
                registrationEpoch: epoch,
                revocationCapability: revocationCapability,
                registrationRevision: expectedRevision
            )
        )
        for conflictAttempt in 0...MatrixPushRegistrationRetryPolicy.maximumConflictRetries {
            try Task.checkCancellation()
            guard registrationContextIsCurrent(
                token: token,
                appID: appID,
                sessionToken: sessionToken,
                lease: lease
            ) else { throw CancellationError() }
            let attempt = try await APIClient.shared.registerPushToken(
                token: token,
                environment: environment,
                bundleId: appID,
                registrationEpoch: epoch,
                revocationCapability: revocationCapability,
                expectedRevision: expectedRevision
            )
            guard registrationContextIsCurrent(
                token: token,
                appID: appID,
                sessionToken: sessionToken,
                lease: lease
            ) else { throw CancellationError() }
            switch attempt {
            case let .registered(response):
                guard let revision = try response.validatedRegistrationRevision() else {
                    throw MatrixSessionFoundationError.unavailable
                }
                let confirmedHandle = StoredPushRegistrationHandle(
                    token: token,
                    appID: appID,
                    registrationEpoch: epoch,
                    revocationCapability: revocationCapability,
                    registrationRevision: revision
                )
                persistRegistrationRevision(
                    revision,
                    token: token,
                    appID: appID,
                    registrationEpoch: epoch
                )
                try confirmActiveRegistrationHandle(confirmedHandle)
                return response
            case let .ownershipConflict(registrationRevision):
                guard MatrixPushRegistrationRetryPolicy.mayRetry(
                    conflictAttempt: conflictAttempt,
                    contextIsCurrent: true,
                    revision: registrationRevision
                ) else {
                    throw MatrixSessionFoundationError.unavailable
                }
                expectedRevision = registrationRevision
            case .contractUpgradeRequired:
                throw MatrixSessionFoundationError.unavailable
            case .epochRevoked:
                throw MatrixSessionFoundationError.unavailable
            }
        }
        throw MatrixSessionFoundationError.unavailable
    }

    private func registrationContextIsCurrent(
        token: String,
        appID: String,
        sessionToken: String,
        lease: MatrixPushRegistrationFence.Lease
    ) -> Bool {
        guard registrationFence.accepts(lease),
              SessionStorage.token == sessionToken
        else { return false }
        return appID == "com.westreem.app.voip"
            ? latestVoIPToken == token
            : appID == bundleIdentifier && latestDeviceToken == token
    }

    private func removalContextIsCurrent(_ context: RemovalContext) -> Bool {
        switch context {
        case let .activeRegistration(token, appID, sessionToken, lease):
            return registrationContextIsCurrent(
                token: token,
                appID: appID,
                sessionToken: sessionToken,
                lease: lease
            )
        case let .signOut(sessionToken):
            return registrationFence.isSigningOut
                && SessionStorage.token == sessionToken
        }
    }

    private func removalSessionToken(_ context: RemovalContext) -> String {
        switch context {
        case let .activeRegistration(_, _, sessionToken, _),
             let .signOut(sessionToken):
            return sessionToken
        }
    }

    private func unregisterPushTokenWithCAS(
        token: String,
        appID: String,
        context: RemovalContext
    ) async throws -> PushTokenRemovalResponse {
        _ = removalSessionToken(context)
        let epoch = try registrationEpoch(appID: appID)
        let revocationCapability = try registrationRevocationCapability(appID: appID)
        var expectedRevision = storedRegistrationRevision(
            token: token,
            appID: appID,
            registrationEpoch: epoch
        )
        for conflictAttempt in 0...MatrixPushRegistrationRetryPolicy.maximumConflictRetries {
            try Task.checkCancellation()
            guard removalContextIsCurrent(context) else {
                throw CancellationError()
            }
            let attempt = try await APIClient.shared.unregisterPushToken(
                token: token,
                bundleId: appID,
                registrationEpoch: epoch,
                revocationCapability: revocationCapability,
                expectedRevision: expectedRevision
            )
            guard removalContextIsCurrent(context) else {
                throw CancellationError()
            }
            switch attempt {
            case let .removed(response):
                clearRegistrationRevision(
                    appID: appID,
                    token: token,
                    registrationEpoch: epoch
                )
                removeRegistrationHandle(
                    token: token,
                    appID: appID,
                    registrationEpoch: epoch,
                    revocationCapability: revocationCapability
                )
                return response
            case let .ownershipConflict(registrationRevision):
                guard MatrixPushRegistrationRetryPolicy.mayRetry(
                    conflictAttempt: conflictAttempt,
                    contextIsCurrent: true,
                    revision: registrationRevision
                ) else {
                    throw MatrixSessionFoundationError.unavailable
                }
                expectedRevision = registrationRevision
            case .contractUpgradeRequired:
                throw MatrixSessionFoundationError.unavailable
            }
        }
        throw MatrixSessionFoundationError.unavailable
    }

    private func synchronizeMatrixPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String,
        sessionToken: String,
        lease: MatrixPushRegistrationFence.Lease
    ) async throws {
        guard let matrixPusherManager else {
            // `pendingMatrixPusher` was set before this call. Treat missing
            // Matrix readiness as retryable so the caller cannot drain/cancel
            // retry work before Client.setPusher has actually succeeded.
            throw MatrixSessionFoundationError.unavailable
        }
        try await matrixPusherManager.installMatrixPusher(
            configuration: configuration,
            pushKey: pushKey,
            deviceDisplayName: UIDevice.current.name
        )

        if let previous = installedPushKey, previous != pushKey {
            do {
                let response = try await unregisterPushTokenWithCAS(
                    token: previous,
                    appID: bundleIdentifier,
                    context: .activeRegistration(
                        token: pushKey,
                        appID: bundleIdentifier,
                        sessionToken: sessionToken,
                        lease: lease
                    )
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

    /// A transient Matrix sync or pusher request failure must not strand a
    /// valid APNs token until the next login/app launch. Element continuously
    /// reconciles its pusher; this bounded retry keeps the same lifecycle while
    /// capping foreground retry pressure at five minutes.
    private func scheduleRetry() {
        guard retryTask == nil, latestDeviceToken != nil, SessionStorage.token != nil else {
            return
        }
        let attempt = retryAttempt
        retryAttempt = min(retryAttempt + 1, 6)
        let seconds = min(15 * (1 << min(attempt, 4)), 300)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            await self?.uploadLatestTokenIfPossible()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
    }

    private func scheduleVoIPRetry() {
        guard voIPRetryTask == nil,
              latestVoIPToken != nil,
              SessionStorage.token != nil
        else { return }
        let attempt = voIPRetryAttempt
        voIPRetryAttempt = min(voIPRetryAttempt + 1, 6)
        let seconds = min(15 * (1 << min(attempt, 4)), 300)
        voIPRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.voIPRetryTask = nil
            await self?.uploadLatestVoIPTokenIfPossible()
        }
    }

    private func cancelVoIPRetry() {
        voIPRetryTask?.cancel()
        voIPRetryTask = nil
        voIPRetryAttempt = 0
    }

    private func registrationRevisionStorageKey(appID: String) -> String? {
        if appID == bundleIdentifier { return ordinaryRevisionKey }
        if appID == "com.westreem.app.voip" { return voIPRevisionKey }
        return nil
    }

    private func registrationEpochStorageKey(appID: String) -> String? {
        if appID == bundleIdentifier { return ordinaryEpochKey }
        if appID == "com.westreem.app.voip" { return voIPEpochKey }
        return nil
    }

    private func revocationCapabilityStorageKey(appID: String) -> String? {
        if appID == bundleIdentifier { return ordinaryRevocationCapabilityKey }
        if appID == "com.westreem.app.voip" { return voIPRevocationCapabilityKey }
        return nil
    }

    private func opaqueDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func newOpaque256BitValue() throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            randomBytes.count,
            &randomBytes
        ) == errSecSuccess else {
            throw MatrixSessionFoundationError.unavailable
        }
        return Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func v3RegistryAccount(appID: String, environment: String) throws -> String {
        guard [bundleIdentifier, "com.westreem.app.voip"].contains(appID),
              ["sandbox", "production"].contains(environment)
        else { throw MatrixSessionFoundationError.unavailable }
        return "v3|ios|\(environment)|\(appID)"
    }

    private func loadV3Registry(
        appID: String,
        environment: String
    ) throws -> StoredV3Registry {
        let account = try v3RegistryAccount(appID: appID, environment: environment)
        guard let data = PushRegistrationSecureStore.v3Data(for: account) else {
            return StoredV3Registry(version: 3, active: nil, cleanup: [])
        }
        guard let registry = try? JSONDecoder().decode(StoredV3Registry.self, from: data),
              registry.version == 3,
              try registry.active.map(validateV3Record) ?? true,
              try registry.cleanup.allSatisfy(validateV3Record)
        else { throw MatrixSessionFoundationError.unavailable }
        return registry
    }

    private func validateV3Record(_ record: StoredV3PushRegistration) throws -> Bool {
        guard record.version == 3,
              !record.ownerUserID.isEmpty,
              record.platform == "ios",
              ["sandbox", "production"].contains(record.environment),
              [bundleIdentifier, "com.westreem.app.voip"].contains(record.appID),
              isValidRawProviderToken(record.providerToken),
              (try? MatrixOpaquePushKey(rawValue: record.matrixPushKey)) != nil,
              (try? MatrixPushRegistrationEpoch(rawValue: record.registrationEpoch)) != nil,
              (try? MatrixPushRegistrationRevocationCapability(
                  rawValue: record.revocationCapability
              )) != nil,
              record.registrationRevision == nil
                || (try? MatrixPushRegistrationRevision(
                    rawValue: record.registrationRevision!
                )) != nil
        else { return false }
        if let predecessor = record.predecessor {
            guard !predecessor.ownerUserID.isEmpty,
                  predecessor.appID == record.appID,
                  predecessor.platform == record.platform,
                  predecessor.environment == record.environment,
                  isValidRawProviderToken(predecessor.providerToken),
                  (try? MatrixPushRegistrationEpoch(
                      rawValue: predecessor.registrationEpoch
                  )) != nil,
                  (try? MatrixPushRegistrationRevocationCapability(
                      rawValue: predecessor.revocationCapability
                  )) != nil,
                  predecessor.registrationRevision == nil
                    || (try? MatrixPushRegistrationRevision(
                        rawValue: predecessor.registrationRevision!
                    )) != nil,
                  predecessor.matrixPushKey == nil
                    || (try? MatrixOpaquePushKey(
                        rawValue: predecessor.matrixPushKey!
                    )) != nil
            else { return false }
        }
        return true
    }

    private func isValidRawProviderToken(_ value: String) -> Bool {
        (64...512).contains(value.utf8.count)
            && value.utf8.count.isMultiple(of: 2)
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private func persistV3Registry(
        _ registry: StoredV3Registry,
        appID: String,
        environment: String
    ) throws {
        guard registry.version == 3,
              try registry.active.map(validateV3Record) ?? true,
              try registry.cleanup.allSatisfy(validateV3Record),
              let data = try? JSONEncoder().encode(registry),
              PushRegistrationSecureStore.writeV3(
                  data,
                  account: try v3RegistryAccount(appID: appID, environment: environment)
              )
        else { throw MatrixSessionFoundationError.unavailable }
    }

    private func makeV3Record(
        ownerUserID: String,
        providerToken: String,
        appID: String,
        environment: String,
        expectedRevision: String?,
        predecessor: StoredV3Predecessor?
    ) throws -> StoredV3PushRegistration {
        let key = try MatrixOpaquePushKey(
            rawValue: MatrixOpaquePushKey.prefix + newOpaque256BitValue()
        )
        return StoredV3PushRegistration(
            version: 3,
            ownerUserID: ownerUserID,
            providerToken: providerToken,
            matrixPushKey: key.rawValue,
            appID: appID,
            platform: "ios",
            environment: environment,
            registrationEpoch: try newOpaque256BitValue(),
            revocationCapability: try newOpaque256BitValue(),
            registrationRevision: expectedRevision,
            phase: .generated,
            serverState: nil,
            rawRetireAt: nil,
            predecessor: predecessor
        )
    }

    private func v3RecordForCurrentContext(
        ownerUserID: String,
        providerToken: String,
        appID: String,
        environment: String
    ) throws -> StoredV3PushRegistration {
        var registry = try loadV3Registry(appID: appID, environment: environment)
        if let active = registry.active,
           active.ownerUserID == ownerUserID,
           active.providerToken == providerToken,
           active.appID == appID,
           active.environment == environment {
            return active
        }

        var predecessor: StoredV3Predecessor?
        if let active = registry.active {
            // A predecessor proves an account handoff for the exact same APNs
            // provider slot. A new provider token is a distinct slot: queue
            // the old generation for cleanup, but never attach its ownership
            // proof or revision to the fresh token's PREPARE.
            if active.providerToken == providerToken,
               active.ownerUserID != ownerUserID,
               active.appID == appID,
               active.platform == "ios",
               active.environment == environment {
                predecessor = StoredV3Predecessor(
                    ownerUserID: active.ownerUserID,
                    providerToken: active.providerToken,
                    appID: active.appID,
                    platform: active.platform,
                    environment: active.environment,
                    registrationEpoch: active.registrationEpoch,
                    revocationCapability: active.revocationCapability,
                    registrationRevision: active.registrationRevision,
                    matrixPushKey: active.matrixPushKey
                )
            }
            if !registry.cleanup.contains(active) { registry.cleanup.append(active) }
        }

        var expectedRevision: String?
        if registry.active == nil,
           let legacy = registrationHandles(forKey: activeRegistrationHandlesKey)
            .last(where: { $0.token == providerToken && $0.appID == appID }) {
            expectedRevision = legacy.registrationRevision
        }
        let record = try makeV3Record(
            ownerUserID: ownerUserID,
            providerToken: providerToken,
            appID: appID,
            environment: environment,
            expectedRevision: expectedRevision,
            predecessor: predecessor
        )
        registry.active = record
        try persistV3Registry(registry, appID: appID, environment: environment)
        return record
    }

    private func updateV3Record(_ record: StoredV3PushRegistration) throws {
        var registry = try loadV3Registry(
            appID: record.appID,
            environment: record.environment
        )
        guard registry.active?.matrixPushKey == record.matrixPushKey else {
            throw CancellationError()
        }
        registry.active = record
        try persistV3Registry(
            registry,
            appID: record.appID,
            environment: record.environment
        )
    }

    private func registrationEpoch(appID: String) throws -> String {
        guard let key = registrationEpochStorageKey(appID: appID) else {
            throw MatrixSessionFoundationError.unavailable
        }
        if let stored = PushRegistrationSecureStore.string(for: key),
           (try? MatrixPushRegistrationEpoch(rawValue: stored)) != nil {
            return stored
        }

        let epoch = try newOpaque256BitValue()
        _ = try MatrixPushRegistrationEpoch(rawValue: epoch)
        guard PushRegistrationSecureStore.write(epoch, account: key) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return epoch
    }

    private func registrationRevocationCapability(appID: String) throws -> String {
        guard let key = revocationCapabilityStorageKey(appID: appID) else {
            throw MatrixSessionFoundationError.unavailable
        }
        if let stored = PushRegistrationSecureStore.string(for: key),
           (try? MatrixPushRegistrationRevocationCapability(rawValue: stored)) != nil {
            return stored
        }
        let capability = try newOpaque256BitValue()
        _ = try MatrixPushRegistrationRevocationCapability(rawValue: capability)
        guard PushRegistrationSecureStore.write(capability, account: key) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return capability
    }

    private func clearRegistrationEpoch(appID: String) {
        guard let key = registrationEpochStorageKey(appID: appID) else { return }
        PushRegistrationSecureStore.remove(account: key)
    }

    private func clearRevocationCapability(appID: String) {
        guard let key = revocationCapabilityStorageKey(appID: appID) else { return }
        PushRegistrationSecureStore.remove(account: key)
    }

    private func registrationHandles(forKey key: String) -> [StoredPushRegistrationHandle] {
        guard let data = PushRegistrationSecureStore.data(for: key),
              let decoded = try? JSONDecoder().decode(
                  [StoredPushRegistrationHandle].self,
                  from: data
              )
        else { return [] }
        return decoded.filter { handle in
            [bundleIdentifier, "com.westreem.app.voip"].contains(handle.appID)
                && handle.token.count >= 32
                && handle.token == handle.token.lowercased()
                && handle.token.allSatisfy(\.isHexDigit)
                && (try? MatrixPushRegistrationEpoch(
                    rawValue: handle.registrationEpoch
                )) != nil
                && (try? MatrixPushRegistrationRevocationCapability(
                    rawValue: handle.revocationCapability
                )) != nil
                && (handle.registrationRevision == nil
                    || (try? MatrixPushRegistrationRevision(
                        rawValue: handle.registrationRevision!
                    )) != nil)
        }
    }

    @discardableResult
    private func persistRegistrationHandles(
        _ handles: [StoredPushRegistrationHandle],
        forKey key: String
    ) -> Bool {
        guard !handles.isEmpty else {
            PushRegistrationSecureStore.remove(account: key)
            return PushRegistrationSecureStore.data(for: key) == nil
        }
        guard let data = try? JSONEncoder().encode(handles) else { return false }
        return PushRegistrationSecureStore.write(data, account: key)
    }

    private func persistActiveRegistrationHandle(
        _ handle: StoredPushRegistrationHandle
    ) throws {
        var handles = registrationHandles(forKey: activeRegistrationHandlesKey)
        handles.removeAll { sameRegistrationHandle($0, handle) }
        handles.append(handle)
        guard persistRegistrationHandles(handles, forKey: activeRegistrationHandlesKey) else {
            throw MatrixSessionFoundationError.unavailable
        }
    }

    private func confirmActiveRegistrationHandle(
        _ handle: StoredPushRegistrationHandle
    ) throws {
        let confirmed = registrationHandleIdentity(handle)
        var active = registrationHandles(forKey: activeRegistrationHandlesKey)
        active = MatrixPushCleanupQueuePolicy.removingAuthoritativelySuperseded(
            by: confirmed,
            from: active.map(registrationHandleIdentity)
        ).compactMap { retainedIdentity in
            active.last { registrationHandleIdentity($0) == retainedIdentity }
        }
        active.append(handle)
        // Persist the newly authoritative capability before compacting stale
        // cleanup entries. A Keychain failure therefore fails closed without
        // losing the only capability that can revoke the server row.
        guard persistRegistrationHandles(active, forKey: activeRegistrationHandlesKey) else {
            throw MatrixSessionFoundationError.unavailable
        }

        let queued = registrationHandles(forKey: cleanupQueueKey)
        let retainedIdentities = MatrixPushCleanupQueuePolicy
            .removingAuthoritativelySuperseded(
                by: confirmed,
                from: queued.map(registrationHandleIdentity)
            )
        let retained = retainedIdentities.compactMap { retainedIdentity in
            queued.last { registrationHandleIdentity($0) == retainedIdentity }
        }
        // Failure leaves harmless, already-tombstoned cleanup capabilities in
        // place for a later idempotent drain; it never drops a live capability.
        _ = persistRegistrationHandles(retained, forKey: cleanupQueueKey)
    }

    private func enqueueRegistrationHandle(_ handle: StoredPushRegistrationHandle) {
        var queued = registrationHandles(forKey: cleanupQueueKey)
        queued.removeAll { sameRegistrationHandle($0, handle) }
        queued.append(handle)
        // Queue persistence happens before the active handle is cleared.
        guard persistRegistrationHandles(queued, forKey: cleanupQueueKey) else { return }
        var active = registrationHandles(forKey: activeRegistrationHandlesKey)
        active.removeAll { sameRegistrationHandle($0, handle) }
        persistRegistrationHandles(active, forKey: activeRegistrationHandlesKey)
    }

    private func enqueueKnownRegistration(token: String, appID: String) {
        if let handle = registrationHandles(forKey: activeRegistrationHandlesKey)
            .last(where: { $0.token == token && $0.appID == appID }) {
            enqueueRegistrationHandle(handle)
            return
        }
        guard let epochKey = registrationEpochStorageKey(appID: appID),
              let capabilityKey = revocationCapabilityStorageKey(appID: appID),
              let epoch = PushRegistrationSecureStore.string(for: epochKey),
              let capability = PushRegistrationSecureStore.string(for: capabilityKey),
              (try? MatrixPushRegistrationEpoch(rawValue: epoch)) != nil,
              (try? MatrixPushRegistrationRevocationCapability(
                  rawValue: capability
              )) != nil
        else { return }
        enqueueRegistrationHandle(StoredPushRegistrationHandle(
            token: token,
            appID: appID,
            registrationEpoch: epoch,
            revocationCapability: capability,
            registrationRevision: storedRegistrationRevision(
                token: token,
                appID: appID,
                registrationEpoch: epoch
            )
        ))
    }

    private func enqueueAllActiveRegistrationHandlesForCleanup() {
        let active = registrationHandles(forKey: activeRegistrationHandlesKey)
        for handle in active { enqueueRegistrationHandle(handle) }
    }

    private func removeRegistrationHandle(
        token: String,
        appID: String,
        registrationEpoch: String,
        revocationCapability: String
    ) {
        for key in [activeRegistrationHandlesKey, cleanupQueueKey] {
            var handles = registrationHandles(forKey: key)
            let identity = MatrixPushRegistrationHandleIdentity(
                tokenDigest: registrationTokenDigest(token: token, appID: appID),
                appID: appID,
                registrationEpoch: registrationEpoch,
                revocationCapabilityDigest: registrationCapabilityDigest(
                    revocationCapability
                )
            )
            handles.removeAll { registrationHandleIdentity($0) == identity }
            persistRegistrationHandles(handles, forKey: key)
        }
    }

    private func drainPushRegistrationCleanupQueue() async {
        guard !cleanupDrainInProgress else { return }
        cleanupDrainInProgress = true
        defer { cleanupDrainInProgress = false }
        let snapshot = registrationHandles(forKey: cleanupQueueKey)
        for original in snapshot {
            var handle = original
            var removed = false
            for conflictAttempt in 0...MatrixPushRegistrationRetryPolicy.maximumConflictRetries {
                do {
                    let attempt = try await APIClient.shared.unregisterPushToken(
                        token: handle.token,
                        bundleId: handle.appID,
                        registrationEpoch: handle.registrationEpoch,
                        revocationCapability: handle.revocationCapability,
                        expectedRevision: handle.registrationRevision
                    )
                    switch attempt {
                    case let .removed(response):
                        try? await matrixPusherManager?.removeMatrixPusher(
                            try response.matrixRemoval.validated()
                        )
                        removed = true
                    case let .ownershipConflict(registrationRevision):
                        guard MatrixPushRegistrationRetryPolicy.mayRetry(
                            conflictAttempt: conflictAttempt,
                            contextIsCurrent: true,
                            revision: registrationRevision
                        ) else { break }
                        handle.registrationRevision = registrationRevision
                        enqueueRegistrationHandle(handle)
                        continue
                    case .contractUpgradeRequired:
                        break
                    }
                } catch {
                    // Offline, expired-session, and transient failures retain
                    // the non-logged capability handle for the next drain.
                }
                break
            }
            if removed {
                removeRegistrationHandle(
                    token: handle.token,
                    appID: handle.appID,
                    registrationEpoch: handle.registrationEpoch,
                    revocationCapability: handle.revocationCapability
                )
                clearRegistrationRevision(
                    appID: handle.appID,
                    token: handle.token,
                    registrationEpoch: handle.registrationEpoch
                )
            }
        }
    }

    private func registrationTokenDigest(token: String, appID: String) -> String {
        opaqueDigest(appID + "\u{0}" + token.lowercased())
    }

    private func registrationCapabilityDigest(_ capability: String) -> String {
        opaqueDigest("revocation-capability\u{0}" + capability)
    }

    private func registrationHandleIdentity(
        _ handle: StoredPushRegistrationHandle
    ) -> MatrixPushRegistrationHandleIdentity {
        MatrixPushRegistrationHandleIdentity(
            tokenDigest: registrationTokenDigest(
                token: handle.token,
                appID: handle.appID
            ),
            appID: handle.appID,
            registrationEpoch: handle.registrationEpoch,
            revocationCapabilityDigest: registrationCapabilityDigest(
                handle.revocationCapability
            )
        )
    }

    private func sameRegistrationHandle(
        _ left: StoredPushRegistrationHandle,
        _ right: StoredPushRegistrationHandle
    ) -> Bool {
        registrationHandleIdentity(left) == registrationHandleIdentity(right)
    }

    private func storedRegistrationRevision(
        token: String,
        appID: String,
        registrationEpoch: String
    ) -> String? {
        guard let key = registrationRevisionStorageKey(appID: appID),
              let data = PushRegistrationSecureStore.data(for: key),
              let records = try? JSONDecoder().decode(
                  [StoredRegistrationRevision].self,
                  from: data
              )
        else { return nil }
        let digest = registrationTokenDigest(token: token, appID: appID)
        guard let record = records.last(where: {
            $0.tokenDigest == digest && $0.registrationEpoch == registrationEpoch
        }),
              (try? MatrixPushRegistrationRevision(rawValue: record.revision)) != nil
        else { return nil }
        return record.revision
    }

    private func persistRegistrationRevision(
        _ revision: String,
        token: String,
        appID: String,
        registrationEpoch: String
    ) {
        guard let key = registrationRevisionStorageKey(appID: appID),
              (try? MatrixPushRegistrationRevision(rawValue: revision)) != nil
        else { return }
        let digest = registrationTokenDigest(token: token, appID: appID)
        let existing = PushRegistrationSecureStore.data(for: key).flatMap {
            try? JSONDecoder().decode([StoredRegistrationRevision].self, from: $0)
        } ?? []
        // A registration success has already replaced this exact token/app
        // server slot, so revisions for older epochs cannot be live anymore.
        let retained = existing.filter { $0.tokenDigest != digest }
        let records = Array(retained) + [
            StoredRegistrationRevision(
                tokenDigest: digest,
                registrationEpoch: registrationEpoch,
                revision: revision
            ),
        ]
        guard let data = try? JSONEncoder().encode(records) else { return }
        PushRegistrationSecureStore.write(data, account: key)
    }

    private func clearRegistrationRevision(
        appID: String,
        token: String? = nil,
        registrationEpoch: String? = nil
    ) {
        guard let key = registrationRevisionStorageKey(appID: appID) else { return }
        guard let token else {
            PushRegistrationSecureStore.remove(account: key)
            return
        }
        guard let data = PushRegistrationSecureStore.data(for: key),
              let existing = try? JSONDecoder().decode(
                  [StoredRegistrationRevision].self,
                  from: data
              )
        else {
            PushRegistrationSecureStore.remove(account: key)
            return
        }
        let digest = registrationTokenDigest(token: token, appID: appID)
        let retained = existing.filter { record in
            guard record.tokenDigest == digest else { return true }
            guard let registrationEpoch else { return false }
            return record.registrationEpoch != registrationEpoch
        }
        guard !retained.isEmpty,
              let encoded = try? JSONEncoder().encode(retained)
        else {
            PushRegistrationSecureStore.remove(account: key)
            return
        }
        PushRegistrationSecureStore.write(encoded, account: key)
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

    private var installedVoIPPushKey: String? {
        get { UserDefaults.standard.string(forKey: installedVoIPTokenKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: installedVoIPTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: installedVoIPTokenKey)
            }
        }
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.westreem.app"
    }

    private var apnsEnvironment: String? {
        if let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let profileData = try? Data(contentsOf: profileURL),
           let profileText = String(data: profileData, encoding: .isoLatin1),
           let environment = environmentFromProvisioningProfile(profileText) {
            return MatrixPushProviderEnvironment.backendValue(
                forAPNsEnvironment: environment
            )
        }

        #if DEBUG
        return "sandbox"
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
