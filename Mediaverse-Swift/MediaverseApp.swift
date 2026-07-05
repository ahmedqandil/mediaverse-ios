import SwiftUI

@main
struct MediaverseApp: App {
    @UIApplicationDelegateAdaptor(MediaverseAppDelegate.self) var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var miniPlayer = MiniPlayerManager()

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
            .onOpenURL { url in
                auth.handleDeepLink(url)
            }
        }
    }
}
