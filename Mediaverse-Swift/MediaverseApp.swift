import AVFoundation
import SwiftUI

@main
struct MediaverseApp: App {
    private static let processStartedAt = Date()
    @UIApplicationDelegateAdaptor(MediaverseAppDelegate.self) var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var miniPlayer = MiniPlayerManager()
    @StateObject private var platformConfig = PlatformConfigManager()
    @StateObject private var globalUploads = GlobalUploadProgressManager.shared
    @StateObject private var inAppBrowser = InAppBrowserManager()
    @StateObject private var incomingLinks = IncomingLinkCoordinator.shared
    @State private var isShowingBootSplash = true
    @Environment(\.scenePhase) private var scenePhase

    private static let configuredSharedURLCache: Void = {
        URLCache.shared = URLCache(
            memoryCapacity: 96 * 1024 * 1024,
            diskCapacity: 768 * 1024 * 1024,
            diskPath: "MediaverseSharedURLCache"
        )
    }()

    private var deviceActivationSheetBinding: Binding<Bool> {
        Binding(
            get: { auth.isAuthenticated && auth.pendingDeviceActivationCode != nil },
            set: { isPresented in
                if !isPresented {
                    auth.pendingDeviceActivationCode = nil
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                C.bg.ignoresSafeArea()

                Group {
                    if isShowingBootSplash || auth.isLoading {
                        SplashView()
                    } else if auth.isAuthenticated {
                        MainTabView()
                    } else {
                        LoginView()
                    }
                }
            }
            .environmentObject(auth)
            .environmentObject(miniPlayer)
            .environmentObject(platformConfig)
            .environmentObject(globalUploads)
            .environmentObject(inAppBrowser)
            .environmentObject(incomingLinks)
            .environment(\.openURL, OpenURLAction { url in
                if InAppBrowserManager.canDisplayInApp(url) {
                    inAppBrowser.open(url)
                    return .handled
                }
                return .discarded
            })
            .task {
                Task { await platformConfig.refresh() }
                try? await Task.sleep(nanoseconds: 900_000_000)
                isShowingBootSplash = false
                CacheMetrics.shared.recordDuration("startup.bootSplash", startedAt: Self.processStartedAt)
            }
            .onAppear {
                _ = Self.configuredSharedURLCache
                incomingLinks.configure(auth: auth, inAppBrowser: inAppBrowser)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
            }
            .onOpenURL { url in
                incomingLinks.handle(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                incomingLinks.handle(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceActivationRequested)) { notification in
                guard let code = notification.object as? String else { return }
                auth.requestDeviceActivation(code: code)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { await CacheMaintenanceService.shared.trimForMemoryPressure() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                Task { await CacheMaintenanceService.shared.trimForBackground() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Fix 6: refresh the 7-day mobile JWT when the app comes back to foreground
                if newPhase == .active {
                    auth.refreshSessionIfNeeded()
                    incomingLinks.resumePendingAfterAuthentication()
                    Task { await platformConfig.refresh() }
                }
            }
            .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    incomingLinks.resumePendingAfterAuthentication()
                }
            }
            .sheet(isPresented: deviceActivationSheetBinding) {
                if let code = auth.pendingDeviceActivationCode, auth.isAuthenticated {
                    DeviceActivationSheet(userCode: code) {
                        auth.pendingDeviceActivationCode = nil
                    }
                }
            }
            .sheet(item: $inAppBrowser.item) { item in
                InAppBrowserView(url: item.url)
            }
        }
    }
}
