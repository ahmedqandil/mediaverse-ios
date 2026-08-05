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

    static func isTrustedRtcURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        #if DEBUG
        if ["http", "ws"].contains(scheme),
           ["localhost", "127.0.0.1", "::1"].contains(host) {
            return true
        }
        #endif
        guard ["https", "wss"].contains(scheme) else { return false }
        return productionBackendHosts.contains(host)
            || host.hasSuffix(".westreem.com")
            || host.hasSuffix(".fly.dev")
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
    static let bg          = WestreemTokens.Palette.ink950   // ink/950
    static let surface     = WestreemTokens.Palette.ink900   // ink/900
    static let elevated    = WestreemTokens.Palette.ink800   // surface/card
    static let overlay     = WestreemTokens.Palette.ink700   // surface/raised
    static let sunken      = WestreemTokens.Palette.surfaceSunken
    static let selected    = WestreemTokens.Palette.surfaceSelected
    // Legacy alias so existing code using surfaceAlt keeps compiling
    static let surfaceAlt  = Color(hex: "#161824")   // → elevated

    // Text hierarchy
    static let text         = WestreemTokens.Palette.text                              // text
    static let textMuted    = WestreemTokens.Palette.muted                            // text/secondary
    static let textTertiary = WestreemTokens.Palette.textFaint                       // text/faint

    // Borders
    static let borderSubtle  = WestreemTokens.Palette.lineSoft   // line/soft
    static let borderFrame   = WestreemTokens.Palette.lineFrame
    static let borderEdge    = WestreemTokens.Palette.lineEdge
    static let border        = WestreemTokens.Palette.lineHard   // line/hard
    static let borderStrong  = Color.white.opacity(0.22)   // --border-strong

    // Accent colours — super-app palette
    static let watch     = WestreemTokens.Palette.green   // green
    static let watchDim  = WestreemTokens.Palette.greenDim
    static let listen    = Color(hex: "#C77DFF")   // --listen (purple, microdramas)
    static let listenDim = Color(hex: "#9C4DCC")   // --listen-dim
    static let play      = Color(hex: "#40C4FF")   // --play   (light blue)

    // Semantic accent (defaults to watch)
    static let accent = WestreemTokens.Palette.green
    static let danger = WestreemTokens.Palette.pink
    static let warning = Color(hex: "#F2D36B")
    static let success = Color(hex: "#6AE383")

    // ── Layout ───────────────────────────────────────────────────────────────
    /// Content-card radius from the WeStreem Design System.
    static let cardRadius: CGFloat  = WestreemTokens.Radius.card
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

private struct WestreemEditorChrome: ViewModifier {
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(C.text)
            .tint(C.watch)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, alignment: .topLeading)
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

    func westreemEditor(minHeight: CGFloat = 96) -> some View {
        modifier(WestreemEditorChrome(minHeight: minHeight))
    }

    func westreemFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(C.bg)
            .foregroundStyle(C.text)
            .tint(C.watch)
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func westreemFormRow() -> some View {
        listRowBackground(C.surface)
            .listRowSeparatorTint(C.borderSubtle)
    }
}

struct WestreemFeedbackBanner: View {
    enum Kind {
        case error, warning, success, information

        fileprivate var color: Color {
            switch self {
            case .error: C.danger
            case .warning: C.warning
            case .success: C.success
            case .information: C.play
            }
        }

        fileprivate var icon: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .success: "checkmark.circle.fill"
            case .information: "info.circle.fill"
            }
        }
    }

    let message: String
    var kind: Kind = .error

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.color)
                .padding(.top, 1)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(C.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(kind.color.opacity(0.24), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
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

struct WestreemSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(C.text)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(C.elevated.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(C.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

enum WestreemPillTone {
    case primary
    case secondary
    case danger
    case schedule
}

enum WestreemPillDensity {
    case action
    case compact
}

/// WeStreem Design System 04-C. Pills keep one invariant control shape while
/// tone and density communicate hierarchy; no client-local gradients exist.
struct WestreemPillButtonStyle: ButtonStyle {
    let tone: WestreemPillTone
    let density: WestreemPillDensity

    init(tone: WestreemPillTone, density: WestreemPillDensity = .action) {
        self.tone = tone
        self.density = density
    }

    private var foreground: Color {
        switch tone {
        case .primary: WestreemTokens.Palette.greenOn
        case .secondary:
            density == .compact ? Color(hex: "#C2D0CB") : WestreemTokens.Palette.text
        case .danger: WestreemTokens.Palette.pink
        case .schedule: WestreemTokens.Palette.lavender
        }
    }

    private var border: Color {
        switch tone {
        case .primary: .clear
        case .secondary: WestreemTokens.Palette.lineHard
        case .danger: Color(hex: "#5A1E3A")
        case .schedule: Color(hex: "#453072")
        }
    }

    private var borderWidth: CGFloat {
        tone == .primary ? 0 : 1
    }

    private var font: Font {
        if density == .compact {
            return .system(size: 8, weight: .bold, design: .monospaced)
        }
        if tone == .schedule {
            return .system(size: 10, weight: .regular, design: .monospaced)
        }
        return .system(size: 13, weight: tone == .primary ? .bold : .semibold)
    }

    private var horizontalPadding: CGFloat {
        if density == .compact { return 8 }
        return tone == .schedule ? 13 : 18
    }

    private var verticalPadding: CGFloat {
        if density == .compact { return 0 }
        return tone == .schedule ? 7 : 9
    }

    private var fill: AnyShapeStyle {
        switch tone {
        case .primary:
            AnyShapeStyle(WestreemTokens.Palette.green)
        case .secondary:
            AnyShapeStyle(LinearGradient(
                colors: [
                    WestreemTokens.Palette.ink700,
                    WestreemTokens.Palette.surfaceRaisedEnd,
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        case .danger:
            AnyShapeStyle(WestreemTokens.Palette.pinkDim)
        case .schedule:
            AnyShapeStyle(WestreemTokens.Palette.lavenderDim)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .textCase(density == .compact ? .uppercase : nil)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(height: density == .compact ? 24 : nil)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: borderWidth))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(WestreemTokens.Easing.fast, value: configuration.isPressed)
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

struct WestreemImagePositionEditor: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let title: String
    let onCancel: () -> Void
    let onApply: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var actualViewportSize: CGSize = .zero
    @State private var isDragging = false
    @State private var isPinching = false

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    Label("Drag to position · Pinch to zoom", systemImage: "hand.draw")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    GeometryReader { proxy in
                        let width = min(proxy.size.width, 420)
                        let height = width / max(aspectRatio, 0.1)
                        positionedPreview(width: width, height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: aspectRatio < 1 ? 460 : 280)

                    HStack {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: $zoom, in: 1...3) { editing in
                            if !editing {
                                committedZoom = zoom
                                committedOffset = offset
                            }
                        }
                            .tint(C.watch)
                            .onChange(of: zoom) { _, _ in
                                offset = constrainedOffset(offset, viewport: appliedViewportSize)
                            }
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .foregroundStyle(C.textMuted)

                    Button {
                        C.lightHaptic()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            zoom = 1
                            committedZoom = 1
                            offset = .zero
                            committedOffset = .zero
                        }
                    } label: {
                        Label("Reset position", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(C.textMuted)

                    Spacer(minLength: 0)
                }
                .padding(C.pagePad)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(croppedImage(viewport: appliedViewportSize))
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var fallbackViewportSize: CGSize {
        let width: CGFloat = 420
        return CGSize(width: width, height: width / max(aspectRatio, 0.1))
    }

    private var appliedViewportSize: CGSize {
        actualViewportSize.width > 0 && actualViewportSize.height > 0
            ? actualViewportSize
            : fallbackViewportSize
    }

    private func positionedPreview(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black
            Image(uiImage: normalizedImage)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .scaleEffect(zoom)
                .offset(offset)
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45)
                            }
                            offset = constrainedOffset(
                                CGSize(
                                    width: committedOffset.width + value.translation.width,
                                    height: committedOffset.height + value.translation.height
                                ),
                                viewport: CGSize(width: width, height: height)
                            )
                        }
                        .onEnded { _ in
                            isDragging = false
                            committedOffset = offset
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if !isPinching {
                                isPinching = true
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45)
                            }
                            zoom = min(max(committedZoom * value, 1), 3)
                            offset = constrainedOffset(offset, viewport: CGSize(width: width, height: height))
                        }
                        .onEnded { _ in
                            isPinching = false
                            committedZoom = zoom
                            committedOffset = offset
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                )
        }
        .frame(width: width, height: height)
        .onAppear {
            actualViewportSize = CGSize(width: width, height: height)
        }
        .onChange(of: CGSize(width: width, height: height)) { _, size in
            actualViewportSize = size
            offset = constrainedOffset(offset, viewport: size)
            committedOffset = offset
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(C.watch, lineWidth: 2)
        }
        .clipped()
    }

    private var normalizedImage: UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private func constrainedOffset(_ proposed: CGSize, viewport: CGSize) -> CGSize {
        let imageSize = normalizedImage.size
        let baseScale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let displayed = CGSize(
            width: imageSize.width * baseScale * zoom,
            height: imageSize.height * baseScale * zoom
        )
        let maxX = max(0, (displayed.width - viewport.width) / 2)
        let maxY = max(0, (displayed.height - viewport.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func croppedImage(viewport: CGSize) -> UIImage {
        guard let cgImage = normalizedImage.cgImage else { return image }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let baseScale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let effectiveScale = baseScale * zoom
        let displayedSize = CGSize(
            width: imageSize.width * effectiveScale,
            height: imageSize.height * effectiveScale
        )
        let originX = (displayedSize.width - viewport.width) / 2 - offset.width
        let originY = (displayedSize.height - viewport.height) / 2 - offset.height
        let cropRect = CGRect(
            x: originX / effectiveScale,
            y: originY / effectiveScale,
            width: viewport.width / effectiveScale,
            height: viewport.height / effectiveScale
        ).intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = cgImage.cropping(to: cropRect) else { return normalizedImage }
        return UIImage(cgImage: cropped, scale: normalizedImage.scale, orientation: .up)
    }
}

/// Canonical in-content back control used by players and immersive detail pages.
/// Navigation behavior remains owned by the presenting screen.
struct PlatformBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.46))
                    .overlay {
                        Circle().stroke(.white.opacity(0.16), lineWidth: 1)
                    }

                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
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
    static let matrixRoomRouteRequested = Notification.Name("matrixRoomRouteRequested")
    static let matrixWaveVisibilityChanged = Notification.Name("matrixWaveVisibilityChanged")
    static let sessionExpired = Notification.Name("sessionExpired")
    static let horizontalCarouselInteractionChanged = Notification.Name("horizontalCarouselInteractionChanged")
}
