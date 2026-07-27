import SwiftUI
import UIKit

enum C {
    // ── API ──────────────────────────────────────────────────────────────────
    /// Base URL of the Mediaverse web backend (no trailing slash).
    /// Override in scheme environment variables: MEDIAVERSE_BASE_URL
    static var baseURL: String {
        ProcessInfo.processInfo.environment["MEDIAVERSE_BASE_URL"]
            ?? "https://www.westreem.com"
    }

    /// Separate ad decision/serving service. Override in scheme environment variables.
    static var adServerURL: String {
        ProcessInfo.processInfo.environment["MEDIAVERSE_AD_SERVER_URL"]
            ?? ProcessInfo.processInfo.environment["AD_SERVER_URL"]
            ?? ProcessInfo.processInfo.environment["NEXT_PUBLIC_AD_SERVER_URL"]
            ?? "https://mediaverse-adserver.fly.dev/v1"
    }

    static let productionBackendHosts: Set<String> = [
        "westreem.com",
        "www.westreem.com"
    ]

    static let productionAdHosts: Set<String> = [
        "mediaverse-adserver.fly.dev"
    ]

    static func isTrustedBackendURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        #if DEBUG
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) {
            return true
        }
        #endif

        guard scheme == "https" else { return false }
        return productionBackendHosts.contains(host) || host.hasSuffix(".westreem.com")
    }

    static func isTrustedAdURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        #if DEBUG
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) {
            return true
        }
        #endif

        guard scheme == "https" else { return false }
        return productionAdHosts.contains(host)
    }

    static func isTrustedBrowserURL(_ url: URL) -> Bool {
        isTrustedBackendURL(url)
    }

    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func mediaURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil {
            guard url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        let path = value.hasPrefix("/") ? value : "/\(value)"
        guard let url = URL(string: baseURL + path), isTrustedBackendURL(url) else {
            return nil
        }
        return url
    }

    // ── Colors (exact match to web globals.css CSS variables) ─────────────
    // Background depth hierarchy
    static let bg          = Color(hex: "#080810")   // --bg-base / --night
    static let surface     = Color(hex: "#0F1019")   // --bg-surface
    static let elevated    = Color(hex: "#161824")   // --bg-elevated
    static let overlay     = Color(hex: "#1E1F30")   // --bg-overlay
    // Legacy alias so existing code using surfaceAlt keeps compiling
    static let surfaceAlt  = Color(hex: "#161824")   // → elevated

    // Text hierarchy
    static let text         = Color(hex: "#F0F0F5")                              // --text-primary
    static let textMuted    = Color(red: 240/255, green: 240/255, blue: 245/255).opacity(0.64)  // --text-secondary
    static let textTertiary = Color(red: 240/255, green: 240/255, blue: 245/255).opacity(0.48)  // --text-tertiary

    // Borders
    static let borderSubtle  = Color.white.opacity(0.06)   // --border-subtle
    static let border        = Color.white.opacity(0.10)   // --border-default
    static let borderStrong  = Color.white.opacity(0.22)   // --border-strong

    // Accent colours — super-app palette
    static let watch     = Color(hex: "#00E676")   // --watch  (green)
    static let watchDim  = Color(hex: "#00C853")   // --watch-dim
    static let listen    = Color(hex: "#C77DFF")   // --listen (purple, microdramas)
    static let listenDim = Color(hex: "#9C4DCC")   // --listen-dim
    static let play      = Color(hex: "#40C4FF")   // --play   (light blue)

    // Semantic accent (defaults to watch)
    static let accent = Color(hex: "#00E676")

    // ── Layout ───────────────────────────────────────────────────────────────
    static let cardRadius: CGFloat  = 12
    static let pagePad: CGFloat     = 16
    static let sectionSpacing: CGFloat = 36
    static let rowSpacing: CGFloat = 18
    static let gridSpacing: CGFloat = 24
    static let heroHeight: CGFloat = 290
    static let bottomMenuClearance: CGFloat = 96
    static let tabPillHeight: CGFloat = 36
    static let tabPillMinWidth: CGFloat = 104
    static let mainTabWidth: CGFloat = 86
    static let mainTabHeight: CGFloat = 60

    // ── Media aspect ratios ───────────────────────────────────────────────────
    // Container ratios are driven by the server content type, not the source
    // image dimensions. This keeps shorts vertical, shows/posters portrait, and
    // regular videos/episodes landscape across feeds, search, and collections.
    static func mediaAspectRatio(forContentType type: String?) -> CGFloat {
        switch normalizedContentType(type) {
        case "short", "shorts", "reel", "reels", "vertical", "microdrama", "microdramas", "micro-drama", "micro-dramas":
            return 9.0 / 16.0
        case "show", "shows", "series", "tv", "poster", "posters":
            return 2.0 / 3.0
        default:
            return 16.0 / 9.0
        }
    }

    static func normalizedContentType(_ type: String?) -> String {
        type?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        ?? ""
    }

    static func lightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - WeStreem form system

/// Shared form chrome derived from the upload/video panel. It keeps sheets and
/// full-screen editors visually consistent without changing their form state or
/// submission behavior.
struct WestreemFormPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(C.bg.ignoresSafeArea())
        .tint(C.watch)
    }
}

struct WestreemFormPanel<Content: View>: View {
    let title: String?
    let helper: String?
    let content: Content

    init(
        _ title: String? = nil,
        helper: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.helper = helper
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty {
                Text(title.uppercased())
                    .font(.caption2.bold())
                    .tracking(0.45)
                    .foregroundStyle(C.textTertiary)
            }

            content

            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(C.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct WestreemFieldChrome: ViewModifier {
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(C.text)
            .tint(C.watch)
            .padding(.horizontal, 12)
            .frame(minHeight: minHeight)
            .background(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(C.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

extension View {
    func westreemField(minHeight: CGFloat = 46) -> some View {
        modifier(WestreemFieldChrome(minHeight: minHeight))
    }

    func westreemFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(C.bg)
            .tint(C.watch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func westreemFormRow() -> some View {
        listRowBackground(C.surface)
            .listRowSeparatorTint(C.borderSubtle)
    }
}

struct WestreemPrimaryButtonStyle: ButtonStyle {
    let isBusy: Bool

    init(isBusy: Bool = false) {
        self.isBusy = isBusy
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(C.watch.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .opacity(isBusy ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Horizontal rails announce gesture ownership so parent section pagers can
/// yield while a carousel is being dragged.
struct WestreemHorizontalScrollView<Content: View>: View {
    let showsIndicators: Bool
    let content: Content

    init(
        showsIndicators: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: showsIndicators) {
            content
        }
        .simultaneousGesture(horizontalOwnershipGesture)
    }

    private var horizontalOwnershipGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                NotificationCenter.default.post(
                    name: .horizontalCarouselInteractionChanged,
                    object: true
                )
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    NotificationCenter.default.post(
                        name: .horizontalCarouselInteractionChanged,
                        object: false
                    )
                }
            }
    }
}

private struct HorizontalCarouselGestureOwnership: ViewModifier {
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    NotificationCenter.default.post(
                        name: .horizontalCarouselInteractionChanged,
                        object: true
                    )
                }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        NotificationCenter.default.post(
                            name: .horizontalCarouselInteractionChanged,
                            object: false
                        )
                    }
                }
        )
    }
}

extension View {
    func ownsHorizontalCarouselGesture() -> some View {
        modifier(HorizontalCarouselGestureOwnership())
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension Notification.Name {
    static let appContextDidChange = Notification.Name("appContextDidChange")
    static let mentionNavigationRequested = Notification.Name("mentionNavigationRequested")
    static let pushRouteRequested = Notification.Name("pushRouteRequested")
    static let deviceActivationRequested = Notification.Name("deviceActivationRequested")
    static let userFollowChanged = Notification.Name("userFollowChanged")
    static let uploadRequested = Notification.Name("uploadRequested")
    static let uploadEligibilityChanged = Notification.Name("uploadEligibilityChanged")
    static let rippleCreated = Notification.Name("rippleCreated")
    static let profileTabRequested = Notification.Name("profileTabRequested")
    static let exploreSectionRequested = Notification.Name("exploreSectionRequested")
    static let shortsTabRequested = Notification.Name("shortsTabRequested")
    static let commentsOverlayVisibilityChanged = Notification.Name("commentsOverlayVisibilityChanged")
    static let shortsAdPlaybackVisibilityChanged = Notification.Name("shortsAdPlaybackVisibilityChanged")
    static let routedShortsVisibilityChanged = Notification.Name("routedShortsVisibilityChanged")
    static let mainTabScrollToTopRequested = Notification.Name("mainTabScrollToTopRequested")
    static let notificationCountsDidChange = Notification.Name("notificationCountsDidChange")
    static let sessionExpired = Notification.Name("sessionExpired")
    static let horizontalCarouselInteractionChanged = Notification.Name("horizontalCarouselInteractionChanged")
}
