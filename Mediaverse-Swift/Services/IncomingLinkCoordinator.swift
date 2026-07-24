import Foundation

@MainActor
final class IncomingLinkCoordinator: ObservableObject {
    static let shared = IncomingLinkCoordinator()

    private weak var auth: AuthManager?
    private weak var inAppBrowser: InAppBrowserManager?
    private var pendingRoute: AppRoute?
    private var pendingDeviceActivationCode: String?
    private var pendingHandoffID: String?
    private var postedPendingHandoffID: String?

    private init() {}

    func configure(auth: AuthManager, inAppBrowser: InAppBrowserManager) {
        self.auth = auth
        self.inAppBrowser = inAppBrowser
    }

    func handle(_ url: URL) {
        if let code = AuthManager.deviceActivationCode(from: url) {
            pendingDeviceActivationCode = code
            auth?.requestDeviceActivation(code: code)
            NotificationCenter.default.post(name: .deviceActivationRequested, object: code)
            return
        }

        if AuthManager.isAuthenticationLink(url) {
            auth?.handleDeepLink(url)
            return
        }

        if let handoffID = Self.handoffPublicID(from: url) {
            openOrDeferHandoff(handoffID)
            return
        }

        if let route = AppRoute.route(link: url.absoluteString) {
            openRoute(route)
            return
        }

        if C.isTrustedBrowserURL(url) {
            inAppBrowser?.open(url)
        }
    }

    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        if let code = AuthManager.deviceActivationCode(from: userInfo) {
            pendingDeviceActivationCode = code
            auth?.requestDeviceActivation(code: code)
            NotificationCenter.default.post(name: .deviceActivationRequested, object: code)
            return
        }

        if let link = Self.notificationLink(from: userInfo), let url = Self.url(from: link) {
            handle(url)
            return
        }

        if let route = AppRoute.notificationRoute(userInfo: userInfo) {
            openRoute(route)
        }
    }

    func deferHandoffForAuthentication(_ publicId: String) {
        pendingHandoffID = publicId
        postedPendingHandoffID = nil
    }

    func resumePendingAfterAuthentication() {
        guard auth?.isAuthenticated == true,
              let publicId = pendingHandoffID,
              postedPendingHandoffID != publicId else { return }
        postedPendingHandoffID = publicId
        openRoute(.handoff(publicId))
    }

    func clearPendingHandoff(_ publicId: String) {
        if pendingHandoffID == publicId {
            pendingHandoffID = nil
            postedPendingHandoffID = nil
        }
    }

    func consumePendingRoute() -> AppRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    func consumePendingDeviceActivationCode() -> String? {
        defer { pendingDeviceActivationCode = nil }
        return pendingDeviceActivationCode
    }

    func fallbackHandoffURL(publicId: String) -> URL? {
        URL(string: C.baseURL + "/handoff/" + C.pathSegment(publicId))
    }

    private func openOrDeferHandoff(_ publicId: String) {
        guard auth?.isAuthenticated == true else {
            deferHandoffForAuthentication(publicId)
            return
        }
        openRoute(.handoff(publicId))
    }

    private func openRoute(_ route: AppRoute) {
        pendingRoute = route
        NotificationCenter.default.post(name: .pushRouteRequested, object: route)
    }

    private static func notificationLink(from userInfo: [AnyHashable: Any]) -> String? {
        let keys = ["linkUrl", "link_url", "url", "deeplink", "deepLink"]
        for key in keys {
            if let value = userInfo[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = userInfo[AnyHashable(key)] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func url(from link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        let path = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return URL(string: C.baseURL + path)
    }

    static func handoffPublicID(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let isAppScheme = scheme == "westreem"
        let isTrustedWebLink = scheme == "https" && ["westreem.com", "www.westreem.com"].contains(host)
        guard isAppScheme || isTrustedWebLink else { return nil }

        let parts = normalizedPathParts(from: url)
        guard parts.count >= 2, parts[0].lowercased() == "handoff" else { return nil }
        let publicId = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return publicId.isEmpty ? nil : publicId
    }

    private static func normalizedPathParts(from url: URL) -> [String] {
        var parts = [String]()
        if url.scheme?.lowercased() == "westreem", let host = url.host, !host.isEmpty {
            parts.append(host)
        }
        parts.append(contentsOf: url.path.split(separator: "/").map(String.init))
        return parts
    }
}
