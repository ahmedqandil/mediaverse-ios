import SwiftUI

struct HandoffResolverView: View {
    let publicId: String

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var inAppBrowser: InAppBrowserManager
    @EnvironmentObject private var incomingLinks: IncomingLinkCoordinator
    @State private var state: HandoffState = .loading

    init(publicId: String) {
        self.publicId = publicId
    }

    enum HandoffState: Equatable {
        case loading
        case opening(String)
        case terminal(title: String, message: String)
        case failed(title: String, message: String, canRetry: Bool)
    }

    var body: some View {
        VStack(spacing: 18) {
            statusIcon
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(C.text)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if case .failed(_, _, let canRetry) = state, canRetry {
                Button {
                    Task { await resolve() }
                } label: {
                    Text("Try again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: 220)
                        .frame(height: 46)
                        .background(C.watch, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("TV handoff")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: publicId) {
            await resolve()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(C.watch)
                .scaleEffect(1.1)
        case .opening:
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(C.watch)
        case .terminal:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(C.watch)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color(hex: "#F59E0B"))
        }
    }

    private var title: String {
        switch state {
        case .loading:
            return "Opening request"
        case .opening(let title):
            return title
        case .terminal(let title, _), .failed(let title, _, _):
            return title
        }
    }

    private var message: String {
        switch state {
        case .loading:
            return "Checking this TV request for your signed-in account."
        case .opening:
            return "Continue here, then return to your TV when access is active."
        case .terminal(_, let message), .failed(_, let message, _):
            return message
        }
    }

    @MainActor
    private func resolve() async {
        guard auth.isAuthenticated else {
            incomingLinks.deferHandoffForAuthentication(publicId)
            state = .failed(title: "Sign in required", message: "Sign in to continue this TV request.", canRetry: false)
            return
        }

        state = .loading
        do {
            let handoff = try await APIClient.shared.fetchDeviceHandoff(publicId: publicId)
            guard isUsable(handoff) else { return }
            _ = try? await APIClient.shared.updateDeviceHandoff(publicId: publicId, action: "open")
            openDestination(handoff.destination)
        } catch {
            handleResolutionError(error)
        }
    }

    @MainActor
    private func isUsable(_ handoff: DeviceHandoffResponse) -> Bool {
        switch handoff.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "created", "open", "opened", "pending":
            return true
        case "expired":
            incomingLinks.clearPendingHandoff(publicId)
            state = .terminal(title: "Request expired", message: "This TV request has expired. Start it again from your TV.")
            return false
        case "completed", "complete":
            incomingLinks.clearPendingHandoff(publicId)
            state = .terminal(title: "Already completed", message: "This request was already completed. You can return to your TV.")
            return false
        case "cancelled", "canceled":
            incomingLinks.clearPendingHandoff(publicId)
            state = .terminal(title: "Request cancelled", message: "This TV request was cancelled.")
            return false
        default:
            return true
        }
    }

    @MainActor
    private func openDestination(_ destination: DeviceHandoffDestination?) {
        guard let destination else {
            openFallback()
            return
        }

        switch destination.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "show_access":
            guard let showId = destination.showId, !showId.isEmpty else {
                openFallback()
                return
            }
            incomingLinks.clearPendingHandoff(publicId)
            state = .opening("Opening show")
            NotificationCenter.default.post(
                name: .pushRouteRequested,
                object: AppRoute.showAccess(
                    showId: showId,
                    productId: destination.productId,
                    intent: destination.intent,
                    handoffId: publicId
                )
            )
        case "subscription_sales", "subscription_checkout":
            state = .opening("Opening subscription")
            openFallback()
        default:
            openFallback()
        }
    }

    @MainActor
    private func openFallback() {
        guard let url = incomingLinks.fallbackHandoffURL(publicId: publicId) else {
            state = .failed(title: "Cannot open request", message: "This handoff link is invalid.", canRetry: false)
            return
        }
        incomingLinks.clearPendingHandoff(publicId)
        inAppBrowser.open(url)
    }

    @MainActor
    private func handleResolutionError(_ error: Error) {
        switch error {
        case APIError.unauthorized:
            incomingLinks.deferHandoffForAuthentication(publicId)
            Task { await auth.signOut() }
            state = .failed(title: "Sign in required", message: "Sign in again to continue this TV request.", canRetry: false)
        case APIError.http(401):
            incomingLinks.deferHandoffForAuthentication(publicId)
            Task { await auth.signOut() }
            state = .failed(title: "Sign in required", message: "Sign in again to continue this TV request.", canRetry: false)
        case APIError.http(403):
            incomingLinks.clearPendingHandoff(publicId)
            state = .failed(title: "Wrong account", message: "This request belongs to another account.", canRetry: false)
        case APIError.http(404):
            incomingLinks.clearPendingHandoff(publicId)
            state = .failed(title: "Request unavailable", message: "This TV request is invalid or expired.", canRetry: false)
        default:
            state = .failed(title: "Cannot open request", message: error.localizedDescription, canRetry: true)
        }
    }
}
