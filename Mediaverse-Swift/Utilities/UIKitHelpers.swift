import SwiftUI
import Foundation
import UIKit
import AVKit
import AVFoundation
import CallKit
import PushKit
import UserNotifications

/// A bounded, privacy-safe diagnostic surface for the system-call path. The
/// file is intentionally readable from the app data container so a physical
/// device test can identify the first missing boundary without privileged
/// unified-log access or foregrounding the app.
final class MatrixNativeRtcBreadcrumbRecorder: @unchecked Sendable {
    static let shared = MatrixNativeRtcBreadcrumbRecorder()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let maximumFileBytes = 128 * 1_024
    private var sequence: UInt64 = 0

    private var directoryURL: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("RtcDiagnostics", isDirectory: true)
    }

    private var currentURL: URL? {
        directoryURL?.appendingPathComponent("rtc-breadcrumbs.jsonl")
    }

    private var previousURL: URL? {
        directoryURL?.appendingPathComponent("rtc-breadcrumbs.previous.jsonl")
    }

    private init() {}

    func record(
        _ stage: MatrixNativeRtcBreadcrumbEvent,
        reason: MatrixNativeRtcBreadcrumbReason? = nil,
        credentialByteCount: Int? = nil,
        tokenPresent: Bool? = nil,
        canAcceptCalls: Bool? = nil,
        error: Error? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let directoryURL, let currentURL, let previousURL else { return }

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            sequence &+= 1
            let nsError = error.map { $0 as NSError }
            let entry = MatrixNativeRtcBreadcrumb(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                sequence: sequence,
                build: Self.buildLabel,
                stage: stage,
                reason: reason,
                credentialByteCount: credentialByteCount,
                tokenPresent: tokenPresent,
                canAcceptCalls: canAcceptCalls,
                errorDomain: nsError?.domain,
                errorCode: nsError?.code
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try rotateIfNeeded(
                incomingBytes: line.count,
                currentURL: currentURL,
                previousURL: previousURL
            )
            if !fileManager.fileExists(atPath: currentURL.path) {
                _ = fileManager.createFile(atPath: currentURL.path, contents: nil)
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: currentURL.path
                )
            }
            let handle = try FileHandle(forWritingTo: currentURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
        } catch {
            // Diagnostics must never alter PushKit or CallKit behavior.
        }
    }

    private func rotateIfNeeded(
        incomingBytes: Int,
        currentURL: URL,
        previousURL: URL
    ) throws {
        let currentBytes = (
            try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        ) ?? 0
        guard currentBytes + incomingBytes > maximumFileBytes else { return }
        if fileManager.fileExists(atPath: previousURL.path) {
            try fileManager.removeItem(at: previousURL)
        }
        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.moveItem(at: currentURL, to: previousURL)
        }
    }

    private static var buildLabel: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return "\(short) (\(build))"
    }
}

// MARK: - AppDelegate (orientation lock for fullscreen video)

/// App delegate wired via @UIApplicationDelegateAdaptor in MediaverseApp.
/// The static `orientationLock` flag is set to `.allButUpsideDown` before
/// presenting fullscreen video and reset to `.portrait` on dismiss.
class MediaverseAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushNotificationManager.shared.registerNotificationCategories()
        WestreemCallKitCoordinator.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MediaverseAppDelegate.orientationLock
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotificationManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotificationManager.shared.didFailToRegister(error: error)
    }
}

struct WestreemCallDescriptor: Hashable, Sendable {
    let uuid: UUID
    let roomID: String
    let eventID: String?
    let redemptionID: UUID?
    let displayName: String
    let hasVideo: Bool
    let invitationExpiresAtMilliseconds: Int64?
}

extension Notification.Name {
    static let westreemCallKitAnswered = Notification.Name("westreem.callkit.answered")
    static let westreemCallKitEnded = Notification.Name("westreem.callkit.ended")
    static let westreemCallKitMuteChanged = Notification.Name("westreem.callkit.mute")
    static let westreemCallKitAudioSessionChanged = Notification.Name(
        "westreem.callkit.audio-session"
    )
}

/// System calling surface. Matrix call membership remains authoritative; this
/// coordinator only owns iOS ringing, audio-session activation, and CallKit
/// lifecycle reporting.
@MainActor
final class WestreemCallKitCoordinator: NSObject, @preconcurrency CXProviderDelegate, PKPushRegistryDelegate {
    static let shared = WestreemCallKitCoordinator()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var calls: [UUID: WestreemCallDescriptor] = [:]
    private var answeredCalls = Set<UUID>()
    private var mutedCalls = Set<UUID>()
    private var audioSessionActive = false

    private override init() {
        // CallKit derives the localized provider name from the app bundle on
        // current iOS versions; the explicit-name initializer is unsupported.
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = true
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        MatrixNativeRtcBreadcrumbRecorder.shared.record(.startup, reason: .started)
    }

    func startOutgoing(roomID: String, displayName: String, hasVideo: Bool) async throws -> UUID {
        let descriptor = WestreemCallDescriptor(
            uuid: UUID(),
            roomID: roomID,
            eventID: nil,
            redemptionID: nil,
            displayName: displayName,
            hasVideo: hasVideo,
            invitationExpiresAtMilliseconds: nil
        )
        MatrixNativeLiveKitCallAudio.prepareForCallKit()
        calls[descriptor.uuid] = descriptor
        let handle = CXHandle(type: .generic, value: displayName)
        let action = CXStartCallAction(call: descriptor.uuid, handle: handle)
        action.isVideo = hasVideo
        do {
            try await controller.request(CXTransaction(action: action))
            return descriptor.uuid
        } catch {
            calls.removeValue(forKey: descriptor.uuid)
            MatrixNativeLiveKitCallAudio.releaseCallKitLifecycle()
            throw error
        }
    }

    func reportConnected(_ uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    var hasActiveCall: Bool {
        !calls.isEmpty
    }

    func acceptedCallDescriptor(for roomID: String) -> WestreemCallDescriptor? {
        calls.first(where: {
            answeredCalls.contains($0.key) && $0.value.roomID == roomID
        })?.value
    }

    func isMuted(_ uuid: UUID) -> Bool {
        mutedCalls.contains(uuid)
    }

    func isActive(_ uuid: UUID) -> Bool {
        calls[uuid] != nil
    }

    func microphonePublicationEnabled(for uuid: UUID) -> Bool {
        audioSessionActive && !mutedCalls.contains(uuid)
    }

    func end(_ uuid: UUID) async {
        try? await controller.request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    func providerDidReset(_ provider: CXProvider) {
        calls.removeAll()
        answeredCalls.removeAll()
        mutedCalls.removeAll()
        audioSessionActive = false
        MatrixNativeLiveKitCallAudio.resetCallKitLifecycles()
        Task { @MainActor in
            await MatrixNativeIncomingCallRuntime.shared.endAll()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard calls[action.callUUID] != nil else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = calls[action.callUUID] else {
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .callKitAnswer,
                reason: .failed
            )
            action.fail()
            return
        }
        let tokenPresent = SessionStorage.token != nil
        let canAcceptCalls = MatrixNativeIncomingCallRuntime.shared.canAcceptCalls
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .callAcceptance,
            reason: canAcceptCalls ? .accepted : .rejectedNoSession,
            tokenPresent: tokenPresent,
            canAcceptCalls: canAcceptCalls
        )
        guard canAcceptCalls else {
            calls.removeValue(forKey: action.callUUID)
            answeredCalls.remove(action.callUUID)
            MatrixNativeLiveKitCallAudio.releaseCallKitLifecycle()
            provider.reportCall(
                with: action.callUUID,
                endedAt: Date(),
                reason: .failed
            )
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .callKitAnswer,
                reason: .rejectedNoSession
            )
            action.fail()
            return
        }
        let route = MatrixNativePushRoute(roomID: call.roomID, eventID: call.eventID)
        answeredCalls.insert(action.callUUID)
        MatrixNativeIncomingCallRuntime.shared.prepare(
            call,
            muted: mutedCalls.contains(action.callUUID),
            audioSessionActive: audioSessionActive
        )
        MatrixNativeIncomingCallRuntime.shared.activate(action.callUUID)
        MatrixNativePushRouteStore.shared.stage(route)
        NotificationCenter.default.post(name: .westreemCallKitAnswered, object: call)
        NotificationCenter.default.post(name: .matrixRoomRouteRequested, object: route)
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .callKitAnswer,
            reason: .accepted
        )
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let call = calls.removeValue(forKey: action.callUUID)
        answeredCalls.remove(action.callUUID)
        mutedCalls.remove(action.callUUID)
        MatrixNativeLiveKitCallAudio.releaseCallKitLifecycle()
        Task { @MainActor in
            await MatrixNativeIncomingCallRuntime.shared.end(
                action.callUUID,
                endCallKit: false
            )
        }
        NotificationCenter.default.post(name: .westreemCallKitEnded, object: call)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if action.isMuted {
            mutedCalls.insert(action.callUUID)
        } else {
            mutedCalls.remove(action.callUUID)
        }
        MatrixNativeIncomingCallRuntime.shared.setMuted(
            action.isMuted,
            callUUID: action.callUUID
        )
        NotificationCenter.default.post(
            name: .westreemCallKitMuteChanged,
            object: calls[action.callUUID],
            userInfo: ["muted": action.isMuted]
        )
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioSessionActive = true
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .audioSession,
            reason: .activated
        )
        MatrixNativeLiveKitCallAudio.activateForCallKit()
        for uuid in answeredCalls {
            MatrixNativeIncomingCallRuntime.shared.setAudioSessionActive(
                true,
                callUUID: uuid
            )
            MatrixNativeIncomingCallRuntime.shared.activate(uuid)
        }
        NotificationCenter.default.post(
            name: .westreemCallKitAudioSessionChanged,
            object: nil,
            userInfo: ["active": true]
        )
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioSessionActive = false
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .audioSession,
            reason: .deactivated
        )
        for uuid in answeredCalls {
            MatrixNativeIncomingCallRuntime.shared.setAudioSessionActive(
                false,
                callUUID: uuid
            )
        }
        NotificationCenter.default.post(
            name: .westreemCallKitAudioSessionChanged,
            object: nil,
            userInfo: ["active": false]
        )
        MatrixNativeLiveKitCallAudio.deactivateForCallKit()
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .voIPTokenCallback,
            reason: .available,
            credentialByteCount: pushCredentials.token.count
        )
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterVoIP(deviceToken: pushCredentials.token)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .voIPTokenCallback,
            reason: .unavailable
        )
        Task { @MainActor in
            PushNotificationManager.shared.didInvalidateVoIPToken()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        MatrixNativeRtcBreadcrumbRecorder.shared.record(
            .pushKitCallback,
            reason: type == .voIP ? .voIP : .nonVoIP
        )
        guard type == .voIP else {
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .pushKitCompletion,
                reason: .completed
            )
            completion()
            return
        }
        Task { @MainActor in
            defer {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushKitCompletion,
                    reason: .completed
                )
                completion()
            }
            let values = payload.dictionaryPayload
            guard let kind = values["kind"] as? String,
                  kind == "matrix_call" || kind == "matrix_call_cancel" else {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .invalidKind
                )
                return
            }
            guard let uuidText = values["callUUID"] as? String,
                  let uuid = UUID(uuidString: uuidText) else {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .invalidCallIdentifier
                )
                return
            }
            guard let roomID = values["matrixRoomId"] as? String,
                  roomID.first == "!",
                  roomID.contains(":") else {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .invalidRoomIdentifier
                )
                return
            }
            if kind == "matrix_call_cancel" {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .validCancellation
                )
                guard let call = calls.removeValue(forKey: uuid) else { return }
                answeredCalls.remove(uuid)
                mutedCalls.remove(uuid)
                MatrixNativeLiveKitCallAudio.releaseCallKitLifecycle()
                await MatrixNativeIncomingCallRuntime.shared.end(
                    uuid,
                    endCallKit: false
                )
                provider.reportCall(
                    with: uuid,
                    endedAt: Date(),
                    reason: .remoteEnded
                )
                NotificationCenter.default.post(
                    name: .westreemCallKitEnded,
                    object: call
                )
                return
            }
            guard let eventID = values["matrixEventId"] as? String,
                  eventID.first == "$",
                  eventID.utf8.count <= 1_025 else {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .invalidEventIdentifier
                )
                return
            }
            let invitationExpiresAtMilliseconds: Int64?
            if let rawExpiry = values["invitationExpiresAtMs"] {
                let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
                guard let number = rawExpiry as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let expiry = Int64(number.stringValue),
                      MatrixNativeRtcInvitationExpiryContract.accepts(
                        expiresAtMilliseconds: expiry,
                        nowMilliseconds: nowMilliseconds
                      ) else {
                    MatrixNativeRtcBreadcrumbRecorder.shared.record(
                        .pushValidation,
                        reason: .invalidInvitationExpiry
                    )
                    return
                }
                invitationExpiresAtMilliseconds = expiry
            } else {
                // Legacy m.call.invite payloads intentionally omit the modern
                // authoritative expiry and retain their existing behavior.
                invitationExpiresAtMilliseconds = nil
            }
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .pushValidation,
                reason: .validCall
            )
            let descriptor = WestreemCallDescriptor(
                uuid: uuid,
                roomID: roomID,
                eventID: eventID,
                redemptionID: UUID(),
                displayName: (values["callerName"] as? String)?.prefix(120).description ?? "Vibes call",
                hasVideo: values["hasVideo"] as? Bool ?? false,
                invitationExpiresAtMilliseconds: invitationExpiresAtMilliseconds
            )
            // PushKit requires a matching CallKit report for every valid VoIP
            // push. If the authenticated owner is absent, report and end the
            // call immediately instead of presenting an answer action that
            // cannot redeem Matrix membership or provider credentials.
            let tokenPresent = SessionStorage.token != nil
            let canAcceptCalls = MatrixNativeIncomingCallRuntime.shared.canAcceptCalls
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .callAcceptance,
                reason: canAcceptCalls ? .accepted : .rejectedNoSession,
                tokenPresent: tokenPresent,
                canAcceptCalls: canAcceptCalls
            )
            guard canAcceptCalls else {
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: descriptor.displayName)
                update.localizedCallerName = descriptor.displayName
                update.hasVideo = descriptor.hasVideo
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .callKitReport,
                    reason: .begin
                )
                do {
                    try await provider.reportNewIncomingCall(with: uuid, update: update)
                    MatrixNativeRtcBreadcrumbRecorder.shared.record(
                        .callKitReport,
                        reason: .success
                    )
                    provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                } catch {
                    MatrixNativeRtcBreadcrumbRecorder.shared.record(
                        .callKitReport,
                        reason: .error,
                        error: error
                    )
                }
                return
            }
            guard calls[uuid] == nil else {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .pushValidation,
                    reason: .duplicateCall
                )
                return
            }
            MatrixNativeLiveKitCallAudio.prepareForCallKit()
            calls[uuid] = descriptor
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: descriptor.displayName)
            update.localizedCallerName = descriptor.displayName
            update.hasVideo = descriptor.hasVideo
            MatrixNativeRtcBreadcrumbRecorder.shared.record(
                .callKitReport,
                reason: .begin
            )
            do {
                try await provider.reportNewIncomingCall(with: uuid, update: update)
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .callKitReport,
                    reason: .success
                )
            } catch {
                MatrixNativeRtcBreadcrumbRecorder.shared.record(
                    .callKitReport,
                    reason: .error,
                    error: error
                )
                calls.removeValue(forKey: uuid)
                MatrixNativeLiveKitCallAudio.releaseCallKitLifecycle()
            }
        }
    }
}

extension MediaverseAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            PushNotificationManager.shared.handleNotificationTap(userInfo: userInfo)
        }
    }
}

extension UIApplication {
    var hasPushNotificationEntitlement: Bool {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL),
              let profileText = String(data: profileData, encoding: .isoLatin1)
        else { return false }

        return profileText.contains("<key>aps-environment</key>")
    }
}

// MARK: - Fullscreen player host

private struct FullscreenWatchPlayer<MarkerOverlay: View>: View {
    let player: AVPlayer
    let heatmapBuckets: [Int]
    let likedSeconds: [Int]
    let isAuthenticated: Bool
    let onLikeMoment: ((Int) -> Void)?
    let showSpoilerToggle: Bool
    let onClipRequest: ClipRequestHandler?
    @Binding var activeClipRange: ClipPlaybackRange?
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let relatedItems: [PlayerRelatedItem]
    let onSelectRelated: ((PlayerRelatedItem) -> Void)?
    let onDismiss: () -> Void
    let markers: () -> MarkerOverlay

    @State private var didRequestDismiss = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WatchPlayerChrome(
                player: player,
                heatmapBuckets: heatmapBuckets,
                likedSeconds: likedSeconds,
                isAuthenticated: isAuthenticated,
                onLikeMoment: onLikeMoment,
                showSpoilerToggle: showSpoilerToggle,
                onClipRequest: onClipRequest,
                activeClipRange: $activeClipRange,
                onPrevious: onPrevious,
                onNext: onNext,
                onBack: requestDismissOnce,
                onFullscreen: requestDismissOnce,
                isFullscreenPresentation: true,
                relatedItems: relatedItems,
                onSelectRelated: { item in
                    onSelectRelated?(item)
                }
            ) {
                markers()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation == .portrait || orientation == .portraitUpsideDown {
                requestDismissOnce()
            }
        }
    }

    private func requestDismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss()
    }
}

private struct FullscreenAdPlayer: View {
    let player: AVPlayer
    let presentation: ActiveAdPresentation?
    let onSkip: (() -> Void)?
    let onAdCompleted: (() -> Void)?
    let onAdFinished: (() -> Void)?
    let onDismiss: () -> Void

    @State private var didRequestDismiss = false
    @State private var didSkipCurrentAd = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let presentation {
                NativeAdPlayerView(
                    decision: presentation.decision,
                    contentId: presentation.contentId,
                    placement: presentation.placement,
                    userId: presentation.userId,
                    breakId: presentation.breakId,
                    aspectRatio: 16 / 9,
                    onFullscreen: requestDismissOnce,
                    externalPlayer: player,
                    initialAdIndex: presentation.currentAdIndex,
                    isPresentationOnly: true,
                    brandCardPlacement: .belowPlayer,
                    initialImpressionTracked: presentation.hasTrackedImpression,
                    initialStartTracked: presentation.hasTrackedStart,
                    adPolicy: presentation.adPolicy,
                    adRemoval: presentation.adRemoval,
                    overrideSkippable: presentation.overrideSkippable,
                    overrideSkipAfterSec: presentation.overrideSkipAfterSec,
                    onSkip: {
                        didSkipCurrentAd = true
                    },
                    onFinish: nil,
                    suppressTracking: presentation.suppressTracking,
                    observeExternalCompletion: presentation.observeExternalCompletion
                ) {
                    if didSkipCurrentAd {
                        presentation.onSkip?()
                    } else {
                        presentation.onFinish?()
                    }
                    onAdFinished?()
                    if presentation.currentAdIndex + 1 >= presentation.decision.ads.count {
                        onAdCompleted?()
                    }
                    requestDismissOnce()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    WatchPlayerSurface(player: player)
                        .background(Color.black)
                        .ignoresSafeArea()

                    Text("AD")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.98, green: 0.80, blue: 0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            player.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation == .portrait || orientation == .portraitUpsideDown {
                requestDismissOnce()
            }
        }
    }

    private func requestDismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss()
    }
}

private struct FullscreenServerGuidedAdPlayer: View {
    @ObservedObject var coordinator: ServerAdPlaybackCoordinator
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ServerGuidedAdPlayerView(
                coordinator: coordinator,
                brandCardPlacement: .belowPlayer,
                onFullscreen: onDismiss
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onChange(of: coordinator.presentation) { _, presentation in
            if presentation == nil {
                onDismiss()
            }
        }
    }
}

final class FullScreenPlayerHostVC<Content: View>: UIHostingController<Content> {
    var onDismiss: (() -> Void)?
    private var didNotifyDismiss = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        FullscreenOrientationCoordinator.preferredLandscapeInterfaceOrientation
    }
    override var shouldAutorotate: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed, !didNotifyDismiss else { return }
        didNotifyDismiss = true
        onDismiss?()
    }
}

// MARK: - Fullscreen presentation helper

extension UIViewController {
    /// Walks the presented VC chain to find the topmost presented VC.
    var topMostPresented: UIViewController {
        var vc = self
        while let p = vc.presentedViewController { vc = p }
        return vc
    }
}

/// Presents an active ad player in landscape fullscreen without switching to content playback.
@MainActor
func openFullscreenAdPlayer(
    _ player: AVPlayer,
    presentation: ActiveAdPresentation? = nil,
    onSkip: (() -> Void)? = nil,
    onAdCompleted: (() -> Void)? = nil,
    onAdFinished: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil
) {
    guard let presenter = UIApplication.shared.firstKeyWindow?
        .rootViewController?
        .topMostPresented,
          !(presenter is FullScreenPlayerHostVC<FullscreenAdPlayer>) else {
        player.play()
        return
    }

    var vc: FullScreenPlayerHostVC<FullscreenAdPlayer>!
    let dismissFullscreen = {
        vc.dismiss(animated: true)
    }
    vc = FullScreenPlayerHostVC(
        rootView: FullscreenAdPlayer(
            player: player,
            presentation: presentation,
            onSkip: onSkip,
            onAdCompleted: onAdCompleted,
            onAdFinished: onAdFinished,
            onDismiss: dismissFullscreen
        )
    )
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve
    vc.view.backgroundColor = .black
    vc.onDismiss = {
        ActiveAdFullscreenHandoff.release(player)
        FullscreenOrientationCoordinator.schedulePortraitReset()
        onDismiss?()
    }

    MediaverseAppDelegate.orientationLock = .landscape
    ActiveAdFullscreenHandoff.protect(player)
    presenter.present(vc, animated: true) {
        requestFullscreenLandscapeGeometry()
        player.play()
    }
}

/// Presents the active AVFoundation interstitial using the same ad chrome as CSAI.
@MainActor
func openFullscreenServerAdPlayer(
    _ coordinator: ServerAdPlaybackCoordinator,
    onDismiss: (() -> Void)? = nil
) {
    guard let player = coordinator.interstitialPlayer,
          let presenter = UIApplication.shared.firstKeyWindow?
            .rootViewController?
            .topMostPresented,
          !(presenter is FullScreenPlayerHostVC<FullscreenServerGuidedAdPlayer>) else {
        coordinator.interstitialPlayer?.play()
        return
    }

    var vc: FullScreenPlayerHostVC<FullscreenServerGuidedAdPlayer>!
    let dismissFullscreen = {
        vc.dismiss(animated: true)
    }
    vc = FullScreenPlayerHostVC(
        rootView: FullscreenServerGuidedAdPlayer(
            coordinator: coordinator,
            onDismiss: dismissFullscreen
        )
    )
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve
    vc.view.backgroundColor = .black
    vc.onDismiss = {
        FullscreenOrientationCoordinator.schedulePortraitReset()
        onDismiss?()
    }

    MediaverseAppDelegate.orientationLock = .landscape
    presenter.present(vc, animated: true) {
        requestFullscreenLandscapeGeometry()
        player.play()
    }
}

/// Presents `player` in the custom landscape fullscreen player.
/// The same AVPlayer instance is reused, so playback continues at the same position.
@MainActor
func openFullscreenPlayer<MarkerOverlay: View>(
    _ player: AVPlayer,
    heatmapBuckets: [Int] = [],
    likedSeconds: [Int] = [],
    isAuthenticated: Bool = false,
    onLikeMoment: ((Int) -> Void)? = nil,
    showSpoilerToggle: Bool = false,
    onClipRequest: ClipRequestHandler? = nil,
    activeClipRange: Binding<ClipPlaybackRange?> = .constant(nil),
    onPrevious: (() -> Void)? = nil,
    onNext: (() -> Void)? = nil,
    relatedItems: [PlayerRelatedItem] = [],
    onSelectRelated: ((PlayerRelatedItem) -> Void)? = nil,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder markers: @escaping () -> MarkerOverlay
) {
    MediaverseAppDelegate.orientationLock = .landscape
    let shouldResumeOnPresent = player.timeControlStatus != .paused || player.rate > 0

    var vc: FullScreenPlayerHostVC<FullscreenWatchPlayer<MarkerOverlay>>!
    let dismissFullscreen = {
        vc.dismiss(animated: true)
    }
    let view = FullscreenWatchPlayer(
        player: player,
        heatmapBuckets: heatmapBuckets,
        likedSeconds: likedSeconds,
        isAuthenticated: isAuthenticated,
        onLikeMoment: onLikeMoment,
        showSpoilerToggle: showSpoilerToggle,
        onClipRequest: onClipRequest,
        activeClipRange: activeClipRange,
        onPrevious: onPrevious,
        onNext: onNext,
        relatedItems: relatedItems,
        onSelectRelated: onSelectRelated,
        onDismiss: dismissFullscreen,
        markers: markers
    )
    vc = FullScreenPlayerHostVC(rootView: view)
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve
    vc.view.backgroundColor = .black
    vc.onDismiss = {
        let shouldResumeAfterDismiss = player.timeControlStatus != .paused || player.rate > 0
        FullscreenOrientationCoordinator.schedulePortraitReset()
        onDismiss?()
        if shouldResumeAfterDismiss {
            DispatchQueue.main.async {
                player.playImmediately(atRate: max(player.rate, 1))
            }
        }
    }

    UIApplication.shared.firstKeyWindow?
        .rootViewController?
        .topMostPresented
        .present(vc, animated: true) {
            requestFullscreenLandscapeGeometry()
            if shouldResumeOnPresent {
                player.playImmediately(atRate: max(player.rate, 1))
            }
        }
}

@MainActor
fileprivate enum FullscreenOrientationCoordinator {
    private static var portraitResetTask: Task<Void, Never>?

    static var preferredLandscapeInterfaceOrientation: UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return UIApplication.shared.firstKeyWindow?.windowScene?.interfaceOrientation.isLandscape == true
                ? UIApplication.shared.firstKeyWindow?.windowScene?.interfaceOrientation ?? .landscapeRight
                : .landscapeRight
        }
    }

    static func schedulePortraitReset() {
        portraitResetTask?.cancel()
        portraitResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            resetToPortrait()
        }
    }

    static func resetToPortrait() {
        MediaverseAppDelegate.orientationLock = .portrait
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            UIApplication.shared.firstKeyWindow?
                .rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
            return
        }

        let root = windowScene.keyWindow?.rootViewController ?? UIApplication.shared.firstKeyWindow?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .portrait)
        ) { _ in
            DispatchQueue.main.async {
                root?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }

    static func requestLandscape() {
        portraitResetTask?.cancel()
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscape)
        ) { _ in }
    }
}

@MainActor
private func requestFullscreenLandscapeGeometry() {
    FullscreenOrientationCoordinator.requestLandscape()
}

// MARK: - Share sheet helpers

extension UIActivityViewController {
    /// Present the share sheet from the key window's root view controller.
    @MainActor
    func presentFromRoot() {
        UIApplication.shared.firstKeyWindow?.rootViewController?.topMostPresented.present(self, animated: true)
    }
}

extension UIImage {
    var normalizedForStoryMedia: UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    var storyPortraitNormalized: UIImage {
        let normalized = normalizedForStoryMedia
        guard let cgImage = normalized.cgImage, cgImage.width > cgImage.height else {
            return normalized
        }
        return UIImage(cgImage: cgImage, scale: normalized.scale, orientation: .left).normalizedForStoryMedia
    }
}

extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

private struct InteractiveSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableSwipeBack()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableSwipeBack()
        }

        func enableSwipeBack() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = nil
        }
    }
}

private struct InteractiveSwipeBackDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.disableSwipeBack()
    }

    final class Controller: UIViewController {
        private var previousIsEnabled: Bool?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableSwipeBack()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreSwipeBack()
        }

        func disableSwipeBack() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            if previousIsEnabled == nil {
                previousIsEnabled = gesture.isEnabled
            }
            gesture.isEnabled = false
        }

        private func restoreSwipeBack() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer,
                  let previousIsEnabled else { return }
            gesture.isEnabled = previousIsEnabled
            self.previousIsEnabled = nil
        }
    }
}
// MARK: - Mediaverse icons

struct MediaverseIcon: View {
    let name: String
    let fallbackSystemName: String

    @ViewBuilder
    var body: some View {
        if name == "upload" {
            WestreemUploadIcon()
        } else if UIImage(named: name) != nil {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: fallbackSystemName)
                .resizable()
                .scaledToFit()
        }
    }
}

private struct WestreemUploadIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(size * 0.095, 1.7)

            ZStack {
                Circle()
                    .stroke(lineWidth: lineWidth)
                    .frame(width: size * 0.82, height: size * 0.82)
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)

                PlusMark()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.40, height: size * 0.40)
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct PlusMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct MediaverseLabel: LabelStyle {
    let iconName: String
    let fallbackSystemName: String

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                .frame(width: 15, height: 15)
            configuration.title
        }
    }
}

extension View {
    func mediaverseLabelIcon(_ iconName: String, fallback fallbackSystemName: String) -> some View {
        labelStyle(MediaverseLabel(iconName: iconName, fallbackSystemName: fallbackSystemName))
    }

    func enablesInteractiveSwipeBack() -> some View {
        background(InteractiveSwipeBackEnabler().frame(width: 0, height: 0))
    }

    func disablesInteractiveSwipeBack() -> some View {
        background(InteractiveSwipeBackDisabler().frame(width: 0, height: 0))
    }
}
