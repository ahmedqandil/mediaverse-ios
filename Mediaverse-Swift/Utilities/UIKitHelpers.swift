import SwiftUI
import UIKit
import AVKit
import UserNotifications

// MARK: - AppDelegate (orientation lock for fullscreen video)

/// App delegate wired via @UIApplicationDelegateAdaptor in MediaverseApp.
/// The static `orientationLock` flag is set to `.allButUpsideDown` before
/// presenting fullscreen video and reset to `.portrait` on dismiss.
class MediaverseAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MediaverseAppDelegate.orientationLock
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task {
            try? await APIClient.shared.registerPushToken(token: token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[push] APNs registration failed: \(error.localizedDescription)")
        #endif
    }
}

extension MediaverseAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
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
    let onClipRequest: ((Int, Int, String, Bool) async throws -> Void)?
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let relatedItems: [PlayerRelatedItem]
    let onSelectRelated: ((PlayerRelatedItem) -> Void)?
    let onDismiss: () -> Void
    let markers: () -> MarkerOverlay

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
                onPrevious: onPrevious,
                onNext: onNext,
                onBack: onDismiss,
                onFullscreen: onDismiss,
                isFullscreenPresentation: true,
                relatedItems: relatedItems,
                onSelectRelated: { item in
                    onSelectRelated?(item)
                    onDismiss()
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
                onDismiss()
            }
        }
    }
}

final class FullScreenPlayerHostVC<Content: View>: UIHostingController<Content> {
    var onDismiss: (() -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismiss?() }
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

/// Presents `player` in the custom landscape fullscreen player.
/// The same AVPlayer instance is reused, so playback continues at the same position.
func openFullscreenPlayer<MarkerOverlay: View>(
    _ player: AVPlayer,
    heatmapBuckets: [Int] = [],
    likedSeconds: [Int] = [],
    isAuthenticated: Bool = false,
    onLikeMoment: ((Int) -> Void)? = nil,
    showSpoilerToggle: Bool = false,
    onClipRequest: ((Int, Int, String, Bool) async throws -> Void)? = nil,
    onPrevious: (() -> Void)? = nil,
    onNext: (() -> Void)? = nil,
    relatedItems: [PlayerRelatedItem] = [],
    onSelectRelated: ((PlayerRelatedItem) -> Void)? = nil,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder markers: @escaping () -> MarkerOverlay
) {
    MediaverseAppDelegate.orientationLock = .allButUpsideDown

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
        resetFullscreenOrientation()
        onDismiss?()
    }

    if let windowScene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscapeRight)
        ) { _ in }
    }

    UIApplication.shared.firstKeyWindow?
        .rootViewController?
        .topMostPresented
        .present(vc, animated: true)
}

private func resetFullscreenOrientation() {
    MediaverseAppDelegate.orientationLock = .portrait
    if let windowScene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .portrait)
        ) { _ in }
    }
}

// MARK: - Share sheet helpers

extension UIActivityViewController {
    /// Present the share sheet from the key window's root view controller.
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
// MARK: - Mediaverse icons

struct MediaverseIcon: View {
    let name: String
    let fallbackSystemName: String

    var body: some View {
        if UIImage(named: name) != nil {
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
}

