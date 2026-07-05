import UIKit
import AVKit

// MARK: - AppDelegate (orientation lock for fullscreen video)

/// App delegate wired via @UIApplicationDelegateAdaptor in MediaverseApp.
/// The static `orientationLock` flag is set to `.allButUpsideDown` before
/// presenting fullscreen video and reset to `.portrait` on dismiss.
class MediaverseAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MediaverseAppDelegate.orientationLock
    }
}

// MARK: - Fullscreen AVPlayerViewController

/// AVPlayerViewController subclass that allows landscape rotation.
/// Presented modally (fullscreen cover style) so its `supportedInterfaceOrientations`
/// takes effect alongside the global AppDelegate lock.
class FullScreenAVPlayerVC: AVPlayerViewController {
    /// Called when the user taps "Done" or the VC is dismissed.
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

/// Presents `player` in a landscape-capable fullscreen `AVPlayerViewController`.
/// The same AVPlayer instance is reused — playback continues at the same position.
func openFullscreenPlayer(_ player: AVPlayer) {
    // Unlock orientation so the fullscreen VC can rotate to landscape.
    MediaverseAppDelegate.orientationLock = .allButUpsideDown

    let vc = FullScreenAVPlayerVC()
    vc.player = player
    vc.videoGravity = .resizeAspect
    vc.showsPlaybackControls = true
    vc.allowsPictureInPicturePlayback = true
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve

    vc.onDismiss = {
        // Re-lock to portrait after dismissal.
        MediaverseAppDelegate.orientationLock = .portrait
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            windowScene.requestGeometryUpdate(
                .iOS(interfaceOrientations: .portrait)
            ) { _ in }
        }
    }

    UIApplication.shared.firstKeyWindow?
        .rootViewController?
        .topMostPresented
        .present(vc, animated: true)
}

// MARK: - Share sheet helpers

extension UIActivityViewController {
    /// Present the share sheet from the key window's root view controller.
    func presentFromRoot() {
        UIApplication.shared.firstKeyWindow?.rootViewController?.topMostPresented.present(self, animated: true)
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
