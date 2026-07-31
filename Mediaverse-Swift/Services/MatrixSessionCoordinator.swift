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

    /// Fetches one credential-free, server-authoritative authentication
    /// decision. A failure in one mechanism never activates the other.
    func startNegotiated(
        westreemUserID: String,
        localEnabled: Bool
    ) async {
        guard localEnabled else {
            state = .disabled
            return
        }
        do {
            let offered = try await ssoBootstrapProvider.matrixSSOBootstrap()
            guard offered.enabled, offered.ownershipVersion == 2 else {
                throw MatrixSessionFoundationError.disabled
            }
            let bootstrap = try offered.validated()
            let rollout = MatrixSessionRollout(
                localEnabled: localEnabled,
                serverEnabled: bootstrap.enabled,
                ownershipVersion: bootstrap.ownershipVersion
            )
            guard rollout.mayStartSDK, let authMode = bootstrap.authMode else {
                throw MatrixSessionFoundationError.disabled
            }
            switch authMode {
            case .sso:
                // startSSO independently revalidates the current server
                // decision before opening ASWebAuthenticationSession.
                await startSSO(
                    westreemUserID: westreemUserID,
                    localEnabled: localEnabled
                )
            case .brokerFallback:
                await start(
                    westreemUserID: westreemUserID,
                    rollout: rollout,
                    expectedHomeserverURL: bootstrap.homeserverURL
                )
            }
        } catch let error as MatrixSessionFoundationError {
            client = nil
            state = .failed(error)
        } catch {
            #if DEBUG
            print(
                "[matrix] negotiated session failed: "
                    + String(reflecting: type(of: error))
                    + " "
                    + String(describing: error)
            )
            #endif
            client = nil
            state = .failed(.unavailable)
        }
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
            let offered = try await ssoBootstrapProvider.matrixSSOBootstrap()
            guard offered.enabled, offered.ownershipVersion == 2 else {
                throw MatrixSessionFoundationError.disabled
            }
            let bootstrap = try offered.validated()
            guard bootstrap.authMode == .sso,
                  let redirectURL = bootstrap.redirectURL
            else {
                throw MatrixSessionFoundationError.invalidSSOConfiguration
            }
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
                if identity.verifies(matrixUserID: restored.userId) {
                    try await install(
                        session: restored,
                        identity: identity,
                        keychain: keychain
                    )
                    return
                }
                // A session can outlive a prior app login. Never let a stale
                // Matrix identity permanently poison reconnect for the current
                // canonical Westreem user.
                keychain.removeSession()
            }

            let built = try await buildClient(
                homeserverURL: bootstrap.homeserverURL,
                identity: identity,
                keychain: keychain
            )
            let ssoHandler = try await built.startSsoLogin(
                redirectUrl: redirectURL,
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
            #if DEBUG
            print(
                "[matrix] SSO session failed: "
                    + String(reflecting: type(of: error))
                    + " "
                    + String(describing: error)
            )
            #endif
            client = nil
            state = .failed(.unavailable)
        }
    }

    func start(
        westreemUserID: String,
        rollout: MatrixSessionRollout = .disabled,
        deviceName: String = "Westreem iOS",
        expectedHomeserverURL: String? = nil
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
                guard identity.verifies(matrixUserID: restored.userId) else {
                    keychain.removeSession()
                    state = .requestingSession
                    let brokered = try await broker.matrixSession(
                        deviceName: deviceName
                    )
                    try await installBrokeredSession(
                        brokered,
                        identity: identity,
                        keychain: keychain,
                        expectedHomeserverURL: expectedHomeserverURL
                    )
                    return
                }
                if let expectedHomeserverURL {
                    guard MatrixHomeserverTrustPolicy
                        .normalizedApprovedOrigin(restored.homeserverUrl)
                        == MatrixHomeserverTrustPolicy
                            .normalizedApprovedOrigin(expectedHomeserverURL)
                    else {
                        keychain.removeSession()
                        throw MatrixSessionFoundationError.invalidHomeserver
                    }
                    // Broker sessions must remain refreshable. Discard a
                    // pre-upgrade access-token-only session and obtain a new
                    // broker envelope instead of installing a session that
                    // will fail as soon as its short-lived token expires.
                    if restored.refreshToken?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty != false {
                        keychain.removeSession()
                    } else {
                        try await install(
                            session: restored,
                            identity: identity,
                            keychain: keychain
                        )
                        return
                    }
                } else {
                    try await install(
                        session: restored,
                        identity: identity,
                        keychain: keychain
                    )
                    return
                }
            }

            state = .requestingSession
            let brokered = try await broker.matrixSession(deviceName: deviceName)
            try await installBrokeredSession(
                brokered,
                identity: identity,
                keychain: keychain,
                expectedHomeserverURL: expectedHomeserverURL
            )
        } catch let error as MatrixSessionFoundationError {
            client = nil
            state = .failed(error)
        } catch {
            #if DEBUG
            print(
                "[matrix] broker session failed: "
                    + String(reflecting: type(of: error))
                    + " "
                    + String(describing: error)
            )
            #endif
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

    private func installBrokeredSession(
        _ brokered: MatrixClientSession,
        identity: MatrixCanonicalIdentity,
        keychain: MatrixSessionKeychain,
        expectedHomeserverURL: String?
    ) async throws {
        guard brokered.isUsable() else {
            throw MatrixSessionFoundationError.unavailable
        }
        guard identity.verifies(matrixUserID: brokered.userId) else {
            throw MatrixSessionFoundationError.identityMismatch(
                expected: identity.matrixUserID,
                received: brokered.userId
            )
        }
        guard MatrixHomeserverTrustPolicy.accepts(brokered.homeserverURL) else {
            throw MatrixSessionFoundationError.invalidHomeserver
        }
        if let expectedHomeserverURL {
            guard MatrixHomeserverTrustPolicy
                .normalizedApprovedOrigin(brokered.homeserverURL)
                == MatrixHomeserverTrustPolicy
                    .normalizedApprovedOrigin(expectedHomeserverURL)
            else {
                throw MatrixSessionFoundationError.invalidHomeserver
            }
        }
        let session = Session(
            accessToken: brokered.accessToken,
            refreshToken: brokered.refreshToken,
            userId: brokered.userId,
            deviceId: brokered.deviceId,
            homeserverUrl: brokered.homeserverURL,
            oauthData: nil,
            slidingSyncVersion: .native
        )
        keychain.saveSessionInKeychain(session: session)
        try await install(session: session, identity: identity, keychain: keychain)
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
    private struct CachedValue<Value> {
        let value: Value
        let storedAt: Date

        func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
            now.timeIntervalSince(storedAt) < ttl
        }
    }

    private let coordinator: MatrixSessionCoordinator
    private let repository: MatrixVibesRepositoryFoundation
    private let directNotificationProvider: MatrixRustSDKDirectNotificationProvider
    private let metadataCacheTTL: TimeInterval = 6
    private let identityPresentationCacheTTL: TimeInterval = 5 * 60
    private let timelineMemoryCacheTTL: TimeInterval = 5 * 60
    private var cachedSpacePermissions: [String: CachedValue<MatrixNativeSpacePermissionSnapshot>] = [:]
    private var cachedWaveManagement: [String: CachedValue<MatrixNativeWaveManagementSnapshot>] = [:]
    private var cachedIdentityPresentations: [String: CachedValue<WestreemMatrixIdentityPresentation>] = [:]
    private var cachedTimelines: [String: CachedValue<MatrixTimelinePage>] = [:]
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
        clearMetadataCaches()
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
            await coordinator.startNegotiated(
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

    func retryConnection() async {
        guard let currentWestreemUserID else {
            lifecycleState = .disconnected
            syncState = .disabled
            return
        }
        await reconcile(westreemUserID: currentWestreemUserID)
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

    private func clearMetadataCaches() {
        cachedSpacePermissions.removeAll()
        cachedWaveManagement.removeAll()
        cachedIdentityPresentations.removeAll()
        cachedTimelines.removeAll()
    }

    private func invalidateWaveMetadata(roomID: String) {
        cachedWaveManagement.removeValue(forKey: roomID)
    }

    private func invalidateTimelineCache(roomID: String) {
        cachedTimelines.removeValue(forKey: timelineMemoryCacheKey(roomID: roomID))
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
        if let cached = cachedSpacePermissions[spaceID], cached.isFresh(ttl: metadataCacheTTL) {
            return cached.value
        }
        let snapshot = try await repository.spacePermissions(spaceID: spaceID)
        cachedSpacePermissions[spaceID] = CachedValue(value: snapshot, storedAt: Date())
        return snapshot
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
        invalidateWaveMetadata(roomID: roomID)
    }

    func waveManagement(
        roomID: String
    ) async throws -> MatrixNativeWaveManagementSnapshot {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        if let cached = cachedWaveManagement[roomID], cached.isFresh(ttl: metadataCacheTTL) {
            return cached.value
        }
        let snapshot = try await repository.waveManagement(roomID: roomID)
        cachedWaveManagement[roomID] = CachedValue(value: snapshot, storedAt: Date())
        return snapshot
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
        invalidateWaveMetadata(roomID: roomID)
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
        invalidateWaveMetadata(roomID: roomID)
    }

    func leaveWave(roomID: String) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.leaveWave(roomID: roomID)
        invalidateWaveMetadata(roomID: roomID)
        invalidateTimelineCache(roomID: roomID)
    }

    func waveMembers(roomID: String) async throws -> [MatrixNativeWaveMember] {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let members = try await repository.waveMembers(roomID: roomID)
        guard
            let room = try? await waveManagement(roomID: roomID),
            room.access == .publicRoom,
            !room.isEncrypted
        else {
            return members
        }
        let presentations = (try? await APIClient.shared
            .resolveMatrixIdentityPresentations(
                matrixUserIDs: members.map(\.userID)
            )) ?? [:]
        let originalOrder = Dictionary(
            uniqueKeysWithValues: members.enumerated().map { ($1.userID, $0) }
        )
        return members.map { member in
            guard let identity = presentations[member.userID] else {
                return member
            }
            return MatrixNativeWaveMember(
                userID: member.userID,
                displayName: MatrixNativeMemberPresentationContract.displayName(
                    identity.displayName,
                    matrixUserID: member.userID
                ),
                avatarURL: identity.avatarUrl ?? member.avatarURL,
                role: member.role,
                state: member.state,
                isCurrentUser: member.isCurrentUser,
                isService: member.isService,
                statusEmoji: member.statusEmoji,
                statusText: member.statusText
            )
        }.sorted { left, right in
            guard left.role == right.role else {
                return (originalOrder[left.userID] ?? 0)
                    < (originalOrder[right.userID] ?? 0)
            }
            return left.displayName.localizedCaseInsensitiveCompare(
                right.displayName
            ) == .orderedAscending
        }
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
              !destinationRoomIDs.isEmpty,
              !requestID.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw MatrixNativeWaveActionError.unavailable
        }
        // Treat the view item as a locator only. Resolve the canonical source
        // from the Matrix SDK immediately before forwarding so caller-supplied
        // sender, body, kind, and inherited provenance can never become the
        // authority for an Echo.
        let sourcePage = try await repository.timeline(
            roomID: sourceRoomID,
            from: nil
        )
        guard let resolvedSource = sourcePage.items.first(where: {
            $0.reference.remoteEventID == sourceEventID
        }),
        resolvedSource.kind != .unableToDecrypt,
        resolvedSource.kind != .redacted
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
                    existingReference: resolvedSource.westreemReference,
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
                    sourceSenderMatrixUserID: resolvedSource.senderID,
                    sourceSenderName: resolvedSource.senderDisplayName,
                    sourceBody: resolvedSource.body,
                    actorWestreemUserID: currentWestreemUserID,
                    existingReference: resolvedSource.westreemReference,
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
        invalidateWaveMetadata(roomID: roomID)
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
        invalidateWaveMetadata(roomID: roomID)
    }

    func updateWaveNotification(
        roomID: String,
        mode: MatrixNativeWaveNotificationMode
    ) async throws {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        try await repository.updateWaveNotification(roomID: roomID, mode: mode)
        invalidateWaveMetadata(roomID: roomID)
    }

    func searchWave(
        roomID: String,
        query: String
    ) async throws -> [MatrixNativeWaveSearchResult] {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        return try await repository.searchWave(roomID: roomID, query: query)
    }

    func cachedTimeline(roomID: String) -> MatrixTimelinePage? {
        let key = timelineMemoryCacheKey(roomID: roomID)
        guard let cached = cachedTimelines[key],
              cached.isFresh(ttl: timelineMemoryCacheTTL) else {
            return nil
        }
        return cached.value
    }

    func timeline(roomID: String, paginate: Bool = false) async throws -> MatrixTimelinePage {
        try requireReady()
        do {
            try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        } catch {
            // Access is gone; the cached page must not outlive it.
            invalidateTimelineCache(roomID: roomID)
            throw error
        }
        let page = try await repository.timeline(
            roomID: roomID,
            from: paginate ? "previous" : nil
        )
        let resolvedPage = await resolvingPublicTimelineIdentities(page, roomID: roomID)
        let cachedPage = cacheTimelinePage(
            resolvedPage,
            roomID: roomID,
            paginate: paginate
        )
        return cachedPage
    }

    func pinnedMessages(roomID: String) async throws -> MatrixTimelinePage {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let page = try await repository.pinned(roomID: roomID)
        return await resolvingPublicTimelineIdentities(page, roomID: roomID)
    }

    func thread(
        roomID: String,
        rootEventID: String,
        paginate: Bool = false
    ) async throws -> MatrixTimelinePage {
        try requireReady()
        try await directNotificationProvider.validateRoomAccess(roomID: roomID)
        let page = try await repository.thread(
            roomID: roomID,
            rootEventID: rootEventID,
            paginateBackwards: paginate
        )
        return await resolvingPublicTimelineIdentities(page, roomID: roomID)
    }

    private func cacheTimelinePage(
        _ page: MatrixTimelinePage,
        roomID: String,
        paginate: Bool
    ) -> MatrixTimelinePage {
        let key = timelineMemoryCacheKey(roomID: roomID)
        let mergedPage: MatrixTimelinePage
        if let cached = cachedTimelines[key]?.value, !cached.items.isEmpty {
            mergedPage = MatrixTimelinePage(
                roomID: page.roomID,
                items: MatrixTimelineMerge.items(
                    existing: cached.items,
                    loaded: page.items,
                    paginate: paginate
                ),
                nextToken: page.nextToken
            )
        } else {
            mergedPage = page
        }
        cachedTimelines = cachedTimelines.filter {
            $0.value.isFresh(ttl: timelineMemoryCacheTTL)
        }
        cachedTimelines[key] = CachedValue(value: mergedPage, storedAt: Date())
        return mergedPage
    }

    private func timelineMemoryCacheKey(roomID: String) -> String {
        "\(currentWestreemUserID ?? "anonymous")::\(roomID)"
    }

    private func identityPresentations(
        matrixUserIDs: [String]
    ) async throws -> [String: WestreemMatrixIdentityPresentation] {
        let uniqueIDs = Array(Set(matrixUserIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }

        var presentations: [String: WestreemMatrixIdentityPresentation] = [:]
        var missingIDs: [String] = []
        for userID in uniqueIDs {
            if let cached = cachedIdentityPresentations[userID],
               cached.isFresh(ttl: identityPresentationCacheTTL) {
                presentations[userID] = cached.value
            } else {
                missingIDs.append(userID)
            }
        }

        if !missingIDs.isEmpty {
            let resolved = try await APIClient.shared.resolveMatrixIdentityPresentations(
                matrixUserIDs: missingIDs
            )
            cachedIdentityPresentations = cachedIdentityPresentations.filter {
                $0.value.isFresh(ttl: identityPresentationCacheTTL)
            }
            let now = Date()
            for (userID, presentation) in resolved {
                cachedIdentityPresentations[userID] = CachedValue(
                    value: presentation,
                    storedAt: now
                )
                presentations[userID] = presentation
            }
        }
        return presentations
    }

    private func resolvingPublicTimelineIdentities(
        _ page: MatrixTimelinePage,
        roomID: String
    ) async -> MatrixTimelinePage {
        guard
            let room = try? await waveManagement(roomID: roomID),
            room.access == .publicRoom,
            !room.isEncrypted,
            let presentations = try? await identityPresentations(
                matrixUserIDs: page.items.map(\.senderID)
            )
        else {
            return page
        }
        return MatrixTimelinePage(
            roomID: page.roomID,
            items: page.items.map { item in
                guard let identity = presentations[item.senderID] else {
                    return item
                }
                return MatrixTimelineItem(
                    id: item.id,
                    reference: item.reference,
                    senderID: item.senderID,
                    senderDisplayName: MatrixNativeMemberPresentationContract
                        .displayName(
                            identity.displayName,
                            matrixUserID: item.senderID
                        ),
                    senderAvatarURL: identity.avatarUrl ?? item.senderAvatarURL,
                    body: item.body,
                    kind: item.kind,
                    timestamp: item.timestamp,
                    isOwn: item.isOwn,
                    isEdited: item.isEdited,
                    localSendState: item.localSendState,
                    reactionCount: item.reactionCount,
                    energy: item.energy,
                    readReceiptCount: item.readReceiptCount,
                    threadReplyCount: item.threadReplyCount,
                    replyPreviews: item.replyPreviews,
                    actions: item.actions,
                    media: item.media,
                    poll: item.poll,
                    westreemReference: item.westreemReference
                )
            },
            nextToken: page.nextToken
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
        guard isReady else {
            throw MatrixSessionFoundationError.unavailable
        }
    }

    private func publishState() async {
        lifecycleState = await coordinator.lifecycleState()
        syncState = await coordinator.syncState()
    }
}
