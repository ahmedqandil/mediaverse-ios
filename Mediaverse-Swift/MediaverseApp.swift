import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

@main
struct MediaverseApp: App {
    private static let processStartedAt = Date()
    @UIApplicationDelegateAdaptor(MediaverseAppDelegate.self) var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var matrixSession = MatrixNativeSessionController()
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
                        AuthenticatedRootView()
                    } else {
                        LoginView()
                    }
                }
            }
            .environmentObject(auth)
            .environmentObject(matrixSession)
            .environmentObject(miniPlayer)
            .environmentObject(platformConfig)
            .environmentObject(globalUploads)
            .environmentObject(inAppBrowser)
            .environmentObject(incomingLinks)
            .preferredColorScheme(.dark)
            .tint(C.watch)
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
            .task(id: auth.currentUser?.id) {
                await matrixSession.reconcile(westreemUserID: auth.currentUser?.id)
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
            .sheet(item: $incomingLinks.incomingShare) { share in
                IncomingShareSheet(share: share) {
                    incomingLinks.dismissIncomingShare()
                }
                .environmentObject(auth)
            }
        }
    }
}

private struct AuthenticatedRootView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var profile: FullProfile?
    @State private var isChecking = true
    @State private var needsOnboarding = false
    @State private var checkGeneration = UUID()

    var body: some View {
        ZStack {
            if isChecking {
                SplashView()
            } else {
                MainTabView()
            }

            if needsOnboarding, let profile {
                NativeOnboardingView(profile: profile) { updated in
                    self.profile = updated
                    auth.currentUser = UserProfile(
                        id: updated.id,
                        name: updated.name,
                        email: updated.email,
                        image: updated.image
                    )
                    withAnimation(.easeOut(duration: 0.25)) {
                        needsOnboarding = false
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .task(id: auth.currentUser?.id) {
            await checkProfile()
        }
    }

    private func checkProfile() async {
        let generation = UUID()
        checkGeneration = generation
        isChecking = true
        do {
            let fetched = try await APIClient.shared.fetchProfile().profile
            guard generation == checkGeneration else { return }
            profile = fetched
            needsOnboarding = fetched.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || fetched.handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        } catch {
            // A temporary profile transport failure must not invalidate a valid session.
            needsOnboarding = false
        }
        if generation == checkGeneration {
            isChecking = false
        }
    }
}

private struct NativeOnboardingView: View {
    let profile: FullProfile
    let onCompleted: (FullProfile) -> Void

    @State private var name: String
    @State private var handle: String
    @State private var bio: String
    @State private var imageURL: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var isUploading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(profile: FullProfile, onCompleted: @escaping (FullProfile) -> Void) {
        self.profile = profile
        self.onCompleted = onCompleted
        _name = State(initialValue: profile.name ?? "")
        _handle = State(initialValue: profile.handle ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _imageURL = State(initialValue: profile.image ?? "")
    }

    private var normalizedHandle: String {
        var value = handle.lowercased().replacingOccurrences(of: "@", with: "")
        value = value.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        while value.first?.isNumber == true || value.first == "_" {
            value.removeFirst()
        }
        return String(value.prefix(30))
    }

    private var canSubmit: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && normalizedHandle.count >= 2
            && !isUploading
            && !isSaving
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WELCOME TO WESTREEM")
                            .font(.caption2.weight(.bold))
                            .tracking(2)
                            .foregroundStyle(C.watch)
                        Text("Create your identity")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(C.text)
                        Text("This activates your personal Atmo so people can find, follow, mention, and connect with you.")
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 22) {
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                ZStack(alignment: .bottomTrailing) {
                                    avatar
                                        .frame(width: 96, height: 96)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(C.border, lineWidth: 1))
                                    Image(systemName: isUploading ? "arrow.triangle.2.circlepath" : "camera.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(C.bg)
                                        .frame(width: 30, height: 30)
                                        .background(C.watch, in: Circle())
                                        .overlay(Circle().stroke(C.surfaceAlt, lineWidth: 3))
                                        .offset(x: 3, y: 3)
                                }
                                .frame(width: 102, height: 102)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(nonEmpty(name) ?? "Your name")
                                    .font(.headline)
                                    .foregroundStyle(C.text)
                                Text("@\(normalizedHandle.isEmpty ? "handle" : normalizedHandle)")
                                    .font(.subheadline)
                                    .foregroundStyle(C.textMuted)
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    Text("Choose profile image")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(C.watch)
                                }
                            }
                            Spacer()
                        }

                        onboardingField(title: "Display name") {
                            TextField(
                                "",
                                text: $name,
                                prompt: Text("How people know you").foregroundStyle(C.textTertiary)
                            )
                                .textInputAutocapitalization(.words)
                                .foregroundStyle(C.text)
                                .tint(C.watch)
                        }
                        onboardingField(title: "Handle") {
                            HStack(spacing: 2) {
                                Text("@").foregroundStyle(C.textMuted)
                                TextField(
                                    "",
                                    text: Binding(
                                    get: { normalizedHandle },
                                    set: { handle = $0 }
                                    ),
                                    prompt: Text("your_handle").foregroundStyle(C.textTertiary)
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(C.text)
                                .tint(C.watch)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("BIO").font(.caption2.weight(.bold)).foregroundStyle(C.textMuted)
                                Spacer()
                                Text("\(bio.count)/160").font(.caption2).foregroundStyle(C.textTertiary)
                            }
                            TextField(
                                "",
                                text: $bio,
                                prompt: Text("What are you into?").foregroundStyle(C.textTertiary),
                                axis: .vertical
                            )
                                .lineLimit(3...5)
                                .onChange(of: bio) { _, value in
                                    if value.count > 160 { bio = String(value.prefix(160)) }
                                }
                                .foregroundStyle(C.text)
                                .tint(C.watch)
                                .padding(14)
                                .frame(minHeight: 108, alignment: .topLeading)
                                .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
                        }

                        Text("Handles use 2–30 lowercase letters, numbers, or underscores and must start with a letter.")
                            .font(.caption2)
                            .foregroundStyle(C.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let errorMessage {
                            WestreemFeedbackBanner(message: errorMessage)
                        }

                        Button {
                            Task { await complete() }
                        } label: {
                            Text(isSaving ? "Creating your Atmo…" : "Enter WeStreem")
                                .font(.headline)
                                .foregroundStyle(C.bg)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(C.watch, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.4)
                    }
                    .padding(20)
                    .background(C.surfaceAlt, in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(C.border, lineWidth: 1))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 36)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .interactiveDismissDisabled()
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let previewImage {
            Image(uiImage: previewImage).resizable().scaledToFill()
        } else if let url = C.mediaURL(imageURL) {
            CachedRemoteImage(url: url, targetSize: CGSize(width: 192, height: 192)) {
                $0.resizable().scaledToFill()
            } placeholder: {
                avatarPlaceholder
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(C.elevated)
            .overlay {
                Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "W").uppercased())
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
    }

    private func onboardingField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(C.textMuted)
            content()
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(C.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let source = UIImage(data: data),
                  let jpeg = resizedJPEG(source) else {
                throw APIError.invalidResponse("The selected image could not be read.")
            }
            previewImage = source
            imageURL = try await APIClient.shared.uploadProfileBlobImage(kind: "avatar", imageData: jpeg)
        } catch {
            errorMessage = "Profile image upload failed. \(error.localizedDescription)"
        }
    }

    private func complete() async {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        do {
            let response = try await APIClient.shared.completeOnboarding(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                handle: normalizedHandle,
                bio: nonEmpty(bio),
                image: nonEmpty(imageURL)
            )
            onCompleted(response.profile)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func resizedJPEG(_ image: UIImage) -> Data? {
        let maxPixel: CGFloat = 1200
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maxPixel ? maxPixel / largest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.86)
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
