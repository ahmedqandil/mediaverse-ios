import AuthenticationServices
import Foundation
import MatrixRustSDK
import SwiftUI
import UIKit

protocol MatrixSessionBroker: Sendable {
    func matrixSession(deviceName: String) async throws -> MatrixClientSession
}

extension APIClient: MatrixSessionBroker {
    func matrixSession(deviceName: String) async throws -> MatrixClientSession {
        let body = try JSONEncoder().encode(["deviceName": String(deviceName.prefix(120))])
        let data = try await socialPostData(path: "/api/matrix/session", body: body)
        return try JSONDecoder().decode(MatrixClientSessionEnvelope.self, from: data).session
    }
}

protocol MatrixSSOBootstrapProviding: Sendable {
    func matrixSSOBootstrap() async throws -> MatrixSSOBootstrap
}

extension APIClient: MatrixSSOBootstrapProviding {
    func matrixSSOBootstrap() async throws -> MatrixSSOBootstrap {
        let deviceFamily = await MainActor.run {
            UIDevice.current.userInterfaceIdiom == .pad ? "IPAD" : "IPHONE"
        }
        let body = try JSONEncoder().encode([
            "platform": "IOS",
            "deviceFamily": deviceFamily,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        ])
        let data = try await socialPostData(path: "/api/matrix/sso/config", body: body)
        return try JSONDecoder().decode(MatrixSSOBootstrap.self, from: data)
    }
}

protocol MatrixSSOWebAuthenticating: AnyObject, Sendable {
    @MainActor
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL
    @MainActor
    func cancel()
}

final class MatrixSSOWebAuthenticator: NSObject, MatrixSSOWebAuthenticating, @unchecked Sendable {
    @MainActor
    private var session: ASWebAuthenticationSession?

    nonisolated override init() {
        super.init()
    }

    @MainActor
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authorizationURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callbackURL, error in
                    self?.session = nil
                    if let authenticationError = error as? ASWebAuthenticationSessionError,
                       authenticationError.code == .canceledLogin {
                        continuation.resume(
                            throwing: MatrixSessionFoundationError.authenticationCancelled
                        )
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(
                            throwing: MatrixSessionFoundationError.unavailable
                        )
                    }
                }
                session.presentationContextProvider = WebAuthAnchor.shared
                // Reuse the existing Westreem browser session for near-silent SSO.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    self.session = nil
                    continuation.resume(throwing: MatrixSessionFoundationError.unavailable)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    @MainActor func cancel() {
        session?.cancel()
        session = nil
    }
}

/// Matrix Rust SDK-owned synchronization, persistence and offline delivery.
///
/// This runtime deliberately exposes no Client-Server HTTP surface. Sliding
/// Sync, local room state, retries and local echoes stay inside the SDK's
/// encrypted SQLite store and durable send queue.
actor MatrixNativeSDKSyncRuntime {
    private static let maximumRetryAttempt = 6

    private let client: Client
    private(set) var state: MatrixNativeSyncState = .disabled

    private var syncService: SyncService?
    private var stateObserver: MatrixNativeSDKSyncObserver?
    private var stateHandle: TaskHandle?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var stopped = false

    init(client: Client) {
        self.client = client
    }

    func start() async throws {
        stopped = false
        retryTask?.cancel()
        retryTask = nil
        state = .starting

        // Room timelines and local echoes are restored from the SDK's
        // encrypted SQLite store before the network becomes available.
        client.enableSendQueueUploadProgress(enable: true)
        let service = try await client
            .syncService()
            .withOfflineMode()
            .withProfilesExtension()
            .withRoomListTimelineLimit(limit: 50)
            .finish()

        let observer = MatrixNativeSDKSyncObserver { [weak self] sdkState in
            Task { await self?.consume(sdkState) }
        }
        let handle = service.state(listener: observer)

        syncService = service
        stateObserver = observer
        stateHandle = handle
        await service.start()
    }

    func stop() async {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        stateHandle?.cancel()
        stateHandle = nil
        stateObserver = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        await client.enableAllSendQueues(enable: false)
        state = .stopped
    }

    func currentState() -> MatrixNativeSyncState {
        state
    }

    private func consume(_ sdkState: SyncServiceState) async {
        guard !stopped else { return }
        switch sdkState {
        case .running:
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            await client.enableAllSendQueues(enable: true)
            state = .running
        case .offline:
            // The SDK retains queued local echoes in its encrypted store. We
            // pause delivery until connectivity/sync recovers.
            await client.enableAllSendQueues(enable: false)
            state = .offline
        case .error, .terminated:
            await client.enableAllSendQueues(enable: false)
            scheduleRecovery()
        case .idle:
            state = .starting
        }
    }

    private func scheduleRecovery() {
        guard retryTask == nil, !stopped else { return }
        retryAttempt += 1
        guard retryAttempt <= Self.maximumRetryAttempt else {
            state = .failed
            return
        }

        let attempt = retryAttempt
        let delay = min(
            UInt64(1 << min(attempt - 1, 5)),
            MatrixNativePersistencePolicy.strongestModel.maximumRetryDelaySeconds
        )
        state = .recovering(attempt: attempt)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.restartAfterFailure()
        }
    }

    private func restartAfterFailure() async {
        retryTask = nil
        guard !stopped else { return }
        stateHandle?.cancel()
        stateHandle = nil
        stateObserver = nil
        if let syncService {
            await syncService.stop()
        }
        syncService = nil
        do {
            try await start()
        } catch {
            scheduleRecovery()
        }
    }
}

private final class MatrixNativeSDKSyncObserver: SyncServiceStateObserver, @unchecked Sendable {
    private let handler: @Sendable (SyncServiceState) -> Void

    init(handler: @escaping @Sendable (SyncServiceState) -> Void) {
        self.handler = handler
    }

    func onUpdate(state: SyncServiceState) {
        handler(state)
    }
}

/// Owns the native SDK client and its encrypted local store. This composition
/// root is not installed into production UI until the v2 rollout contract is
/// enabled by both client and server.
actor MatrixSessionCoordinator {
    private let broker: any MatrixSessionBroker
    private let ssoBootstrapProvider: any MatrixSSOBootstrapProviding
    private let ssoAuthenticator: any MatrixSSOWebAuthenticating
    private(set) var state: MatrixSessionLifecycleState = .disabled
    private var client: Client?
    private var sessionKeychain: MatrixSessionKeychain?
    private var syncRuntime: MatrixNativeSDKSyncRuntime?

    init(
        broker: any MatrixSessionBroker = APIClient.shared,
        ssoBootstrapProvider: any MatrixSSOBootstrapProviding = APIClient.shared,
        ssoAuthenticator: any MatrixSSOWebAuthenticating = MatrixSSOWebAuthenticator()
    ) {
        self.broker = broker
        self.ssoBootstrapProvider = ssoBootstrapProvider
        self.ssoAuthenticator = ssoAuthenticator
    }

    /// Native v2 activation. Synapse SSO is never entered before both the
    /// Westreem-authenticated server and the local rollout explicitly allow it.
    func startSSO(westreemUserID: String, localEnabled: Bool) async {
        guard localEnabled else {
            state = .disabled
            return
        }

        do {
            let identity = try MatrixCanonicalIdentity(westreemUserID: westreemUserID)
            let keychain = MatrixSessionKeychain(expectedIdentity: identity)
            sessionKeychain = keychain

            state = .requestingSession
            let bootstrap = try await ssoBootstrapProvider.matrixSSOBootstrap().validated()
            guard MatrixSessionRollout(
                localEnabled: localEnabled,
                serverEnabled: bootstrap.enabled,
                ownershipVersion: bootstrap.ownershipVersion
            ).mayStartSDK else {
                throw MatrixSessionFoundationError.disabled
            }

            state = .restoring
            if let restored = keychain.storedSession() {
                guard
                    MatrixHomeserverTrustPolicy.accepts(restored.homeserverUrl),
                    MatrixHomeserverTrustPolicy.normalizedApprovedOrigin(restored.homeserverUrl)
                        == MatrixHomeserverTrustPolicy.normalizedApprovedOrigin(bootstrap.homeserverURL)
                else {
                    keychain.removeSession()
                    throw MatrixSessionFoundationError.invalidHomeserver
                }
                try await install(session: restored, identity: identity, keychain: keychain)
                return
            }

            let built = try await buildClient(
                homeserverURL: bootstrap.homeserverURL,
                identity: identity,
                keychain: keychain
            )
            let ssoHandler = try await built.startSsoLogin(
                redirectUrl: bootstrap.redirectURL,
                idpId: bootstrap.idpID
            )
            guard let authorizationURL = URL(string: ssoHandler.url()) else {
                throw MatrixSessionFoundationError.invalidSSOConfiguration
            }

            state = .authorizing
            do {
                let callbackURL = try await ssoAuthenticator.authenticate(
                    at: authorizationURL,
                    callbackScheme: "westreem"
                )
                guard bootstrap.accepts(callbackURL: callbackURL) else {
                    throw MatrixSessionFoundationError.invalidSSOCallback
                }
                try await ssoHandler.finish(callbackUrl: callbackURL.absoluteString)
            }

            let session = try built.session()
            guard identity.verifies(matrixUserID: session.userId) else {
                try? await built.logout()
                throw MatrixSessionFoundationError.identityMismatch(
                    expected: identity.matrixUserID,
                    received: session.userId
                )
            }
            keychain.saveSessionInKeychain(session: session)
            client = built
            try await installSyncRuntime(client: built)
            state = .ready(userID: session.userId, deviceID: session.deviceId)
        } catch let error as MatrixSessionFoundationError {
            client = nil
            state = .failed(error)
        } catch {
            client = nil
            state = .failed(.unavailable)
        }
    }

    func start(
        westreemUserID: String,
        rollout: MatrixSessionRollout = .disabled,
        deviceName: String = "Westreem iOS"
    ) async {
        guard rollout.mayStartSDK else {
            state = .disabled
            return
        }

        do {
            let identity = try MatrixCanonicalIdentity(westreemUserID: westreemUserID)
            let keychain = MatrixSessionKeychain(expectedIdentity: identity)
            sessionKeychain = keychain

            state = .restoring
            if let restored = keychain.storedSession() {
                try await install(session: restored, identity: identity, keychain: keychain)
                return
            }

            state = .requestingSession
            let brokered = try await broker.matrixSession(deviceName: deviceName)
            guard identity.verifies(matrixUserID: brokered.userId) else {
                throw MatrixSessionFoundationError.identityMismatch(
                    expected: identity.matrixUserID,
                    received: brokered.userId
                )
            }
            guard MatrixHomeserverTrustPolicy.accepts(brokered.homeserverURL) else {
                throw MatrixSessionFoundationError.invalidHomeserver
            }
            let session = Session(
                accessToken: brokered.accessToken,
                refreshToken: nil,
                userId: brokered.userId,
                deviceId: brokered.deviceId,
                homeserverUrl: brokered.homeserverURL,
                oauthData: nil,
                slidingSyncVersion: .native
            )
            keychain.saveSessionInKeychain(session: session)
            try await install(session: session, identity: identity, keychain: keychain)
        } catch let error as MatrixSessionFoundationError {
            client = nil
            state = .failed(error)
        } catch {
            client = nil
            state = .failed(.unavailable)
        }
    }

    func disconnect(removeCredential: Bool = false) async {
        Task { @MainActor [ssoAuthenticator] in ssoAuthenticator.cancel() }
        await syncRuntime?.stop()
        syncRuntime = nil
        client = nil
        if removeCredential {
            sessionKeychain?.removeSession()
        }
        sessionKeychain = nil
        state = .disconnected
    }

    func activeClient() -> Client? {
        client
    }

    func installPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String,
        deviceDisplayName: String
    ) async throws {
        guard let client else {
            throw MatrixSessionFoundationError.disabled
        }
        try await client.setPusher(
            identifiers: PusherIdentifiers(
                pushkey: pushKey,
                appId: configuration.appId
            ),
            kind: .http(
                data: HttpPusherData(
                    url: configuration.gatewayUrl,
                    format: .eventIdOnly,
                    defaultPayload: nil
                )
            ),
            appDisplayName: configuration.appDisplayName,
            deviceDisplayName: String(deviceDisplayName.prefix(120)),
            profileTag: nil,
            lang: Locale.current.language.languageCode?.identifier ?? "en",
            append: false
        )
    }

    func removePusher(_ removal: MatrixPusherRemoval) async throws {
        guard let client else {
            throw MatrixSessionFoundationError.disabled
        }
        try await client.deletePusher(
            identifiers: PusherIdentifiers(
                pushkey: removal.pushKey,
                appId: removal.appId
            )
        )
    }

    func lifecycleState() -> MatrixSessionLifecycleState {
        state
    }

    private func install(
        session: Session,
        identity: MatrixCanonicalIdentity,
        keychain: MatrixSessionKeychain
    ) async throws {
        guard identity.verifies(matrixUserID: session.userId) else {
            throw MatrixSessionFoundationError.identityMismatch(
                expected: identity.matrixUserID,
                received: session.userId
            )
        }
        let built = try await buildClient(
            homeserverURL: session.homeserverUrl,
            identity: identity,
            keychain: keychain
        )
        try await built.restoreSession(session: session)
        guard try built.userId() == identity.matrixUserID else {
            throw MatrixSessionFoundationError.identityMismatch(
                expected: identity.matrixUserID,
                received: (try? built.userId()) ?? ""
            )
        }
        client = built
        try await installSyncRuntime(client: built)
        state = .ready(userID: session.userId, deviceID: session.deviceId)
    }

    func syncState() async -> MatrixNativeSyncState {
        guard let syncRuntime else { return .disabled }
        return await syncRuntime.currentState()
    }

    private func installSyncRuntime(client: Client) async throws {
        await syncRuntime?.stop()
        let runtime = MatrixNativeSDKSyncRuntime(client: client)
        try await runtime.start()
        syncRuntime = runtime
    }

    private func buildClient(
        homeserverURL: String,
        identity: MatrixCanonicalIdentity,
        keychain: MatrixSessionKeychain
    ) async throws -> Client {
        guard MatrixHomeserverTrustPolicy.accepts(homeserverURL) else {
            throw MatrixSessionFoundationError.invalidHomeserver
        }
        let directory = try MatrixSessionStorePaths.directory(for: identity)
        let store = SqliteStoreBuilder(
            dataPath: directory.appendingPathComponent("data").path,
            cachePath: directory.appendingPathComponent("cache").path
        ).passphrase(passphrase: try keychain.storePassphrase())

        return try await ClientBuilder()
            .homeserverUrl(url: homeserverURL)
            .sqliteStore(config: store)
            .setSessionDelegate(sessionDelegate: keychain)
            .threadsEnabled(enabled: true, threadSubscriptions: true)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .build()
    }
}

@MainActor
final class MatrixNativeSessionController:
    ObservableObject,
    MatrixNativePusherManaging
{
    private let coordinator: MatrixSessionCoordinator
    private let repository: MatrixVibesRepositoryFoundation
    private let directNotificationProvider: MatrixRustSDKDirectNotificationProvider
    private var activationTask: Task<Void, Never>?
    private var cryptoMaintenanceTask: Task<Void, Never>?
    @Published private(set) var lifecycleState: MatrixSessionLifecycleState = .disabled
    @Published private(set) var syncState: MatrixNativeSyncState = .disabled
    @Published private(set) var currentWestreemUserID: String?

    init(coordinator: MatrixSessionCoordinator = MatrixSessionCoordinator()) {
        self.coordinator = coordinator
        self.repository = MatrixVibesRepositoryFoundation(
            sessionCoordinator: coordinator,
            rollout: MatrixSessionRollout(
                localEnabled: true,
                serverEnabled: true,
                ownershipVersion: 2
            )
        )
        self.directNotificationProvider = MatrixRustSDKDirectNotificationProvider(
            sessionCoordinator: coordinator
        )
        PushNotificationManager.shared.installMatrixPusherManager(self)
    }

    func reconcile(westreemUserID: String?) async {
        activationTask?.cancel()
        cryptoMaintenanceTask?.cancel()
        cryptoMaintenanceTask = nil
        guard let westreemUserID else {
            currentWestreemUserID = nil
            await coordinator.disconnect(removeCredential: false)
            await publishState()
            return
        }
        let localEnabled = SocialFeatureConfiguration.runtime().matrixNativeVibesEnabled
        guard localEnabled else {
            currentWestreemUserID = nil
            await coordinator.disconnect(removeCredential: false)
            await publishState()
            return
        }
        lifecycleState = .requestingSession
        syncState = .starting
        currentWestreemUserID = westreemUserID
        let coordinator = coordinator
        activationTask = Task {
            await coordinator.startSSO(
                westreemUserID: westreemUserID,
                localEnabled: localEnabled
            )
        }
        await activationTask?.value
        await publishState()
        if isReady {
            beginCryptoMaintenance()
            PushNotificationManager.shared.matrixSessionDidBecomeReady()
        }
    }

    private func beginCryptoMaintenance() {
        cryptoMaintenanceTask?.cancel()
        let coordinator = coordinator
        cryptoMaintenanceTask = Task {
            for attempt in 0..<6 {
                guard !Task.isCancelled else { return }
                do {
                    let snapshot = try await coordinator.maintainCryptoLifecycle()
                    // Setup/recovery/verification requires an explicit user
                    // gesture. Automatic retries are only useful while an
                    // already configured backup is converging.
                    guard snapshot.readinessAction == .waitForBackup else { return }
                } catch {
                    // Network and sync recovery are owned by the SDK. Retry
                    // with a bounded backoff and never log crypto material.
                }
                let delay = min(60, 1 << min(attempt, 5))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func installMatrixPusher(
        configuration: MatrixHTTPPusherConfiguration,
        pushKey: String,
        deviceDisplayName: String
    ) async throws {
        try requireReady()
        try await coordinator.installPusher(
            configuration: configuration,
            pushKey: pushKey,
            deviceDisplayName: deviceDisplayName
        )
    }

    func removeMatrixPusher(
        _ removal: MatrixPusherRemoval
    ) async throws {
        try requireReady()
        try await coordinator.removePusher(removal)
    }

    func vibes() async throws -> MatrixVibeDirectoryPage {
        try requireReady()
        return try await repository.vibes(cursor: nil)
    }

    func publicVibes(
        query: String?,
        loadNextPage: Bool = false
    ) async throws -> MatrixPublicVibeDirectoryPage {
        try requireReady()
        return try await repository.publicVibes(
            query: query,
            loadNextPage: loadNextPage
        )
    }

    func joinPublicVibe(_ space: MatrixPublicVibeSummary) async throws {
        try requireReady()
        try await repository.joinPublicVibe(space)
    }

    func createVibe(
        _ draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        try requireReady()
        return try await repository.createVibe(draft)
    }

    func createWave(
        inSpaceID spaceID: String,
        draft: MatrixNativeRoomCreationDraft
    ) async throws -> MatrixNativeCreatedRoom {
        try requireReady()
        if draft.isEncrypted {
            _ = try await coordinator.requireCryptoReadyForEncryptedAction()
        }
        return try await repository.createWave(
            inSpaceID: spaceID,
            draft: draft
        )
    }

    func registerCreatedRoom(
        _ room: MatrixNativeCreatedRoom
    ) async throws -> MatrixNativeCreatedRoom {
        try requireReady()
        return try await repository.registerCreatedRoom(room)
    }

    func spacePermissions(
        spaceID: String
    ) async throws -> MatrixNativeSpacePermissionSnapshot {
        try requireReady()
        return try await repository.spacePermissions(spaceID: spaceID)
    }

    func inviteUsers(_ userIDs: [String], roomID: String) async throws -> [String] {
        try requireReady()
        return try await repository.inviteUsers(userIDs, roomID: roomID)
    }

    func waves(spaceID: String) async throws -> MatrixWaveDirectoryPage {
        try requireReady()
        return try await repository.waves(spaceID: spaceID)
    }

    func refreshLocalWaveActivity(
        rooms: [MatrixWaveSummary]
    ) async throws -> [MatrixWaveSummary] {
        try requireReady()
        return try await repository.refreshLocalWaveActivity(rooms: rooms)
    }

    func waveRules(roomID: String) async throws -> MatrixNativeWaveRulesSnapshot {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.waveRules(roomID: roomID)
    }

    func updateWaveRules(
        _ rules: [MatrixNativeWaveRule],
        currentRevision: Int,
        roomID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        guard let currentWestreemUserID else {
            throw MatrixSessionFoundationError.unavailable
        }
        try await repository.updateWaveRules(
            roomID: roomID,
            state: MatrixNativeWaveRulesState(
                revision: max(currentRevision + 1, 1),
                rules: rules,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                updatedByWestreemUserID: currentWestreemUserID
            )
        )
    }

    func waveManagement(
        roomID: String
    ) async throws -> MatrixNativeWaveManagementSnapshot {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.waveManagement(roomID: roomID)
    }

    func updateWaveProfile(
        roomID: String,
        name: String,
        topic: String,
        avatar: MatrixNativeUpload?,
        removeAvatar: Bool
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.updateWaveProfile(
            roomID: roomID,
            name: name,
            topic: topic,
            avatar: avatar,
            removeAvatar: removeAvatar
        )
    }

    func updateWaveAccess(
        roomID: String,
        access: MatrixNativeWaveAccess,
        history: MatrixNativeWaveHistory
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.updateWaveAccess(
            roomID: roomID,
            access: access,
            history: history
        )
    }

    func leaveWave(roomID: String) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.leaveWave(roomID: roomID)
    }

    func waveMembers(roomID: String) async throws -> [MatrixNativeWaveMember] {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.waveMembers(roomID: roomID)
    }

    func joinedWaveDestinations(
        excludingRoomID: String
    ) async throws -> [MatrixWaveSummary] {
        try requireReady()
        return try await repository.joinedWaveDestinations(
            excludingRoomID: excludingRoomID
        )
    }

    func typingUpdates(roomID: String) async throws -> AsyncStream<[String]> {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.typingUpdates(roomID: roomID)
    }

    func echoMessage(
        _ item: MatrixTimelineItem,
        sourceRoomID: String,
        sourceIsEncrypted: Bool,
        destinationRoomIDs: [String],
        requestID: String
    ) async throws -> MatrixNativeEchoDeliveryResult {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(
            roomID: sourceRoomID
        )
        let sourceRoom = try await repository.waveManagement(
            roomID: sourceRoomID
        )
        guard let sourceEventID = item.reference.remoteEventID,
              let currentWestreemUserID,
              !sourceIsEncrypted,
              !sourceRoom.isEncrypted,
              item.kind != .unableToDecrypt,
              item.kind != .redacted,
              !destinationRoomIDs.isEmpty,
              !requestID.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw MatrixNativeWaveActionError.unavailable
        }
        let eligible = try await repository.joinedWaveDestinations(
            excludingRoomID: sourceRoomID
        )
        let allowedRoomIDs = Set(eligible.map(\.id))
        let requestedRoomIDs = MatrixNativeMatrixEchoContract
            .boundedDestinationRoomIDs(destinationRoomIDs)
            .filter(allowedRoomIDs.contains)
            .filter {
                MatrixNativeMatrixEchoContract.canEcho(
                    existingReference: item.westreemReference,
                    to: $0
                )
            }
        guard !requestedRoomIDs.isEmpty else {
            throw MatrixNativeWaveActionError.notAllowed
        }

        var delivered: [String] = []
        var failed: [String] = []
        for roomID in requestedRoomIDs {
            do {
                try await directNotificationProvider.validateRoomAccess(
                    roomID: roomID
                )
                let destinationRoom = try await repository.waveManagement(
                    roomID: roomID
                )
                guard !destinationRoom.isEncrypted else {
                    throw MatrixNativeWaveActionError.notAllowed
                }
                let transactionID =
                    MatrixNativeMatrixEchoContract.stableTransactionID(
                        requestID: requestID,
                        destinationRoomID: roomID
                    )
                let reference = try MatrixNativeMatrixEchoContract.reference(
                    sourceRoomID: sourceRoomID,
                    sourceEventID: sourceEventID,
                    sourceSenderMatrixUserID: item.senderID,
                    sourceSenderName: item.senderDisplayName,
                    sourceBody: item.body,
                    actorWestreemUserID: currentWestreemUserID,
                    existingReference: item.westreemReference,
                    idempotencyKey: transactionID
                )
                let envelope = try MatrixNativeWestreemReferenceEnvelope(
                    authority: "MATRIX",
                    eventType: MatrixNativeWestreemReferenceContract.shareEventType,
                    content: reference
                )
                try await sendWestreemReference(
                    envelope,
                    roomID: roomID,
                    transactionID: transactionID
                )
                delivered.append(roomID)
            } catch {
                failed.append(roomID)
            }
        }
        guard !delivered.isEmpty else {
            throw MatrixNativeWaveActionError.unavailable
        }
        return MatrixNativeEchoDeliveryResult(
            deliveredRoomIDs: delivered,
            failedRoomIDs: failed
        )
    }

    func updateWaveMemberRole(
        roomID: String,
        userID: String,
        role: MatrixNativeWaveMemberRole
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.updateWaveMemberRole(
            roomID: roomID,
            userID: userID,
            role: role
        )
    }

    func moderateWaveMember(
        roomID: String,
        userID: String,
        action: MatrixNativeWaveModerationAction,
        reason: String?
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.moderateWaveMember(
            roomID: roomID,
            userID: userID,
            action: action,
            reason: reason
        )
    }

    func updateWaveNotification(
        roomID: String,
        mode: MatrixNativeWaveNotificationMode
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.updateWaveNotification(roomID: roomID, mode: mode)
    }

    func searchWave(
        roomID: String,
        query: String
    ) async throws -> [MatrixNativeWaveSearchResult] {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.searchWave(roomID: roomID, query: query)
    }

    func timeline(roomID: String, paginate: Bool = false) async throws -> MatrixTimelinePage {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.timeline(roomID: roomID, from: paginate ? "previous" : nil)
    }

    func pinnedMessages(roomID: String) async throws -> MatrixTimelinePage {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.pinned(roomID: roomID)
    }

    func thread(
        roomID: String,
        rootEventID: String,
        paginate: Bool = false
    ) async throws -> MatrixTimelinePage {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.thread(
            roomID: roomID,
            rootEventID: rootEventID,
            paginateBackwards: paginate
        )
    }

    func sendThreadReply(
        _ body: String,
        roomID: String,
        rootEventID: String,
        mentions: [MatrixNativeMentionTarget] = []
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.sendThreadReply(
            body,
            roomID: roomID,
            rootEventID: rootEventID,
            mentions: mentions
        )
    }

    func toggleEnergy(
        _ key: String,
        item: MatrixTimelineItem,
        roomID: String
    ) async throws -> Bool {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.toggleEnergy(
            roomID: roomID,
            item: item,
            key: key
        )
    }

    func editMessage(
        _ body: String,
        item: MatrixTimelineItem,
        roomID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.editText(roomID: roomID, item: item, body: body)
    }

    func redactMessage(
        item: MatrixTimelineItem,
        roomID: String,
        reason: String? = nil
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.redact(roomID: roomID, item: item, reason: reason)
    }

    func reportMessage(
        item: MatrixTimelineItem,
        roomID: String,
        reason: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.report(roomID: roomID, item: item, reason: reason)
    }

    func setMessagePinned(
        _ pinned: Bool,
        item: MatrixTimelineItem,
        roomID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.setPinned(roomID: roomID, item: item, pinned: pinned)
    }

    func sendText(
        _ text: String,
        mentions: [MatrixNativeMentionTarget] = [],
        roomID: String,
        transactionID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw MatrixSessionFoundationError.unavailable
        }
        try await repository.sendText(
            body,
            mentions: mentions,
            roomID: roomID,
            transactionID: transactionID
        )
    }

    func sendWestreemReference(
        _ envelope: MatrixNativeWestreemReferenceEnvelope,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let contentJSON = try MatrixNativeWestreemReferenceContract.encode(
            eventType: envelope.eventType,
            value: envelope.content
        )
        _ = try await repository.send(
            MatrixOutboundEvent(
                eventType: envelope.eventType,
                contentJSON: contentJSON,
                transactionID: transactionID
            ),
            toRoomID: roomID
        )
    }

    func sendEventLiveStageAction(
        roomID: String,
        content: EventMatrixLiveStageContent
    ) async throws -> String {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let data = try JSONEncoder().encode(content)
        guard let contentJSON = String(data: data, encoding: .utf8) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return try await repository.sendLiveStageAction(
            roomID: roomID,
            eventType: content.action.matrixEventType,
            contentJSON: contentJSON,
            clientRequestID: content.clientRequestId
        )
    }

    func sendEventWatchPartyAction(
        roomID: String,
        content: EventMatrixWatchPartyContent
    ) async throws -> String {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let data = try JSONEncoder().encode(content)
        guard let contentJSON = String(data: data, encoding: .utf8) else {
            throw MatrixSessionFoundationError.unavailable
        }
        return try await repository.sendLiveStageAction(
            roomID: roomID,
            eventType: "com.westreem.watch_party.v1",
            contentJSON: contentJSON,
            clientRequestID: content.clientRequestId
        )
    }

    func retry(transactionID: String, roomID: String) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.retry(transactionID: transactionID)
    }

    func sendAttachments(
        _ uploads: [MatrixNativeUpload],
        caption: String?,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.sendAttachments(
            uploads,
            caption: caption,
            roomID: roomID,
            transactionID: transactionID
        )
    }

    func createPoll(
        question: String,
        options: [String],
        roomID: String,
        transactionID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.createPoll(
            question: question,
            options: options,
            roomID: roomID,
            transactionID: transactionID
        )
    }

    func voteInPoll(roomID: String, eventID: String, optionID: String) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.voteInPoll(
            roomID: roomID,
            eventID: eventID,
            optionIDs: [optionID]
        )
    }

    func sendSticker(
        _ upload: MatrixNativeUpload,
        roomID: String,
        transactionID: String
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.sendSticker(
            upload,
            roomID: roomID,
            transactionID: transactionID
        )
    }

    func mediaData(
        roomID: String,
        media: MatrixNativeMediaDescriptor
    ) async throws -> Data {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let data = try await repository.mediaData(
            roomID: roomID,
            sourceJSON: media.sourceJSON,
            expectedSize: media.size
        )
        try MatrixNativeMediaPolicy.validateDownloadedData(data, descriptor: media)
        return data
    }

    func avatarData(avatarURL: String) async throws -> Data {
        try requireReady()
        return try await repository.avatarData(avatarURL: avatarURL)
    }

    func setTyping(_ isTyping: Bool, roomID: String) async {
        guard isReady else { return }
        guard (try? await directNotificationProvider.validateRoomAccess(roomID: roomID)) != nil else {
            return
        }
        try? await repository.setTyping(isTyping, roomID: roomID)
    }

    func markRead(roomID: String) async {
        guard isReady else { return }
        guard (try? await directNotificationProvider.validateRoomAccess(roomID: roomID)) != nil else {
            return
        }
        try? await repository.markRead(roomID: roomID)
    }

    func acceptInvite(roomID: String) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.acceptInvite(roomID: roomID)
    }

    func declineInvite(roomID: String) async throws {
        try requireReady()
        try await repository.declineInvite(roomID: roomID)
    }

    func beginMatrixRtcMembership(
        roomID: String,
        intent: MatrixNativeRtcIntent
    ) async throws -> String {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.beginRtcMembership(
            roomID: roomID,
            intent: intent,
            livekitServiceURL: C.baseURL + "/api/matrix/rtc"
        )
    }

    func endMatrixRtcMembership(roomID: String) async {
        guard isReady else { return }
        try? await repository.endRtcMembership(roomID: roomID)
    }

    func directMessages() async throws -> [MatrixDirectRoomSummary] {
        try requireReady()
        return try await directNotificationProvider.directRooms()
    }

    func openOrCreateDirectMessage(
        westreemUserID: String,
        displayName: String?,
        avatarURL: String?
    ) async throws -> MatrixDirectRoomSummary {
        try requireReady()
        return try await directNotificationProvider.openOrCreateDirectRoom(
            westreemUserID: westreemUserID,
            displayName: displayName,
            avatarURL: avatarURL
        )
    }

    func matrixNotifications() async throws -> [MatrixNotificationSummary] {
        try requireReady()
        return try await directNotificationProvider.notifications()
    }

    func matrixRoomSummary(roomID: String) async throws -> MatrixWaveSummary {
        try requireReady()
        return try await directNotificationProvider.roomSummary(roomID: roomID)
    }

    func markMatrixNotificationRead(roomID: String) async {
        guard isReady else { return }
        try? await directNotificationProvider.markRead(roomID: roomID)
    }

    func cryptoSecuritySnapshot() async throws -> MatrixNativeCryptoSnapshot {
        try requireReady()
        return try await coordinator.cryptoSnapshot()
    }

    func prepareEncryptedConversation() async throws -> MatrixNativeCryptoSnapshot {
        try requireReady()
        return try await coordinator.requireCryptoReadyForEncryptedAction()
    }

    func enableCryptoRecovery(passphrase: String?) async throws -> String {
        try requireReady()
        return try await coordinator.enableCryptoRecovery(passphrase: passphrase)
    }

    func recoverCryptoIdentity(recoveryKey: String) async throws {
        try requireReady()
        try await coordinator.recoverCryptoIdentity(recoveryKey: recoveryKey)
    }

    func resetCryptoRecoveryKey() async throws -> String {
        try requireReady()
        return try await coordinator.resetCryptoRecoveryKey()
    }

    func makeDeviceVerificationController(
        delegate: SessionVerificationControllerDelegate
    ) async throws -> SessionVerificationController {
        try requireReady()
        return try await coordinator.makeDeviceVerificationController(delegate: delegate)
    }

    func refreshRuntimeState() async {
        await publishState()
    }

    var isReady: Bool {
        if case .ready = lifecycleState { return true }
        return false
    }

    private func requireReady() throws {
        guard SocialFeatureConfiguration.runtime().matrixNativeVibesEnabled,
              isReady else {
            throw MatrixSessionFoundationError.disabled
        }
    }

    private func publishState() async {
        lifecycleState = await coordinator.lifecycleState()
        syncState = await coordinator.syncState()
    }
}
