import AVFoundation
import SwiftUI

@main
struct MediaverseApp: App {
    @UIApplicationDelegateAdaptor(MediaverseAppDelegate.self) var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var miniPlayer = MiniPlayerManager()
    @StateObject private var platformConfig = PlatformConfigManager()

    var body: some Scene {
        WindowGroup {
            ZStack {
                C.bg.ignoresSafeArea()

                Group {
                    if auth.isLoading {
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
            .task {
                await platformConfig.refresh()
            }
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            .onOpenURL { url in
                auth.handleDeepLink(url)
            }
        }
    }
}
