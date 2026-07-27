import SwiftUI
import UIKit
import WebKit

struct InAppBrowserItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
final class InAppBrowserManager: ObservableObject {
    @Published var item: InAppBrowserItem?

    func open(_ url: URL) {
        guard Self.canDisplayInApp(url) else { return }
        item = InAppBrowserItem(url: url)
    }

    func dismiss() {
        item = nil
    }

    static func canDisplayInApp(_ url: URL) -> Bool {
        if C.isTrustedBrowserURL(url) {
            return true
        }
        guard url.scheme?.lowercased() == "https",
              url.host(percentEncoded: false)?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}

struct InAppBrowserView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = true
    @State private var estimatedProgress = 0.0
    @State private var loadError: String?
    @State private var copiedLink = false
    @State private var navigationAction: InAppBrowserNavigationAction?

    private var activeURL: URL { currentURL ?? url }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                InAppWebView(
                    url: url,
                    title: $title,
                    currentURL: $currentURL,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    isLoading: $isLoading,
                    estimatedProgress: $estimatedProgress,
                    loadError: $loadError,
                    navigationAction: $navigationAction
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(C.watch)
                            .frame(width: proxy.size.width * max(0.04, estimatedProgress), height: 2)
                            .animation(.easeOut(duration: 0.16), value: estimatedProgress)
                    }
                    .frame(height: 2)
                }

                if let loadError {
                    browserErrorView(loadError)
                }
            }
            .navigationTitle(title.isEmpty ? displayHost : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: activeURL) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.url = activeURL
                            copiedLink = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copiedLink = false
                            }
                        } label: {
                            Label(copiedLink ? "Link Copied" : "Copy Link", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                        }
                        Divider()
                        Menu {
                            ForEach(availableBrowsers) { browser in
                                Button {
                                    browser.open(activeURL)
                                } label: {
                                    Label(browser.title, systemImage: browser.systemImage)
                                }
                            }
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Browser actions")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        navigationAction = .back
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)

                    Button {
                        navigationAction = .forward
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)

                    Spacer()

                    VStack(spacing: 1) {
                        Image(systemName: activeURL.scheme == "https" ? "lock.fill" : "globe")
                            .font(.system(size: 8, weight: .bold))
                        Text(activeURL.host(percentEncoded: false) ?? displayHost)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        navigationAction = isLoading ? .stop : .reload
                    } label: {
                        Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    }
                    .accessibilityLabel(isLoading ? "Stop loading" : "Reload")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var displayHost: String {
        url.host(percentEncoded: false) ?? "Browser"
    }

    private var availableBrowsers: [ExternalBrowser] {
        ExternalBrowser.available(for: activeURL)
    }

    private func browserErrorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(C.watch)
            Text("Page Couldn’t Load")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Try Again") {
                    loadError = nil
                    navigationAction = .reload
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                Button("Open in Safari") {
                    ExternalBrowser.safari.open(activeURL)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
    }
}

enum InAppBrowserNavigationAction: Equatable {
    case back
    case forward
    case reload
    case stop
}

private struct ExternalBrowser: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let appURL: (URL) -> URL?

    static let safari = ExternalBrowser(id: "safari", title: "Safari", systemImage: "safari") { $0 }

    static let candidates: [ExternalBrowser] = [
        .safari,
        ExternalBrowser(id: "chrome", title: "Chrome", systemImage: "globe") { url in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = url.scheme == "https" ? "googlechromes" : "googlechrome"
            return components.url
        },
        ExternalBrowser(id: "firefox", title: "Firefox", systemImage: "flame") { url in
            var components = URLComponents(string: "firefox://open-url")
            components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            return components?.url
        },
        ExternalBrowser(id: "edge", title: "Microsoft Edge", systemImage: "globe") { url in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = url.scheme == "https" ? "microsoft-edge-https" : "microsoft-edge-http"
            return components.url
        },
        ExternalBrowser(id: "brave", title: "Brave", systemImage: "shield") { url in
            var components = URLComponents(string: "brave://open-url")
            components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            return components?.url
        }
    ]

    static func available(for pageURL: URL) -> [ExternalBrowser] {
        candidates.filter { browser in
            guard let target = browser.appURL(pageURL) else { return false }
            return browser.id == "safari" || UIApplication.shared.canOpenURL(target)
        }
    }

    func open(_ pageURL: URL) {
        guard let target = appURL(pageURL) else { return }
        UIApplication.shared.open(target, options: [:])
    }
}

private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @Binding var title: String
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var estimatedProgress: Double
    @Binding var loadError: String?
    @Binding var navigationAction: InAppBrowserNavigationAction?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mediaverse/InAppBrowser"
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let navigationAction {
            DispatchQueue.main.async {
                self.navigationAction = nil
            }
            switch navigationAction {
            case .back where webView.canGoBack:
                webView.goBack()
            case .forward where webView.canGoForward:
                webView.goForward()
            case .reload:
                loadError = nil
                webView.reload()
            case .stop:
                webView.stopLoading()
            default:
                break
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: InAppWebView
        private weak var webView: WKWebView?
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: InAppWebView) {
            self.parent = parent
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            observations = [
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.title = webView.title ?? "" }
                },
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.currentURL = webView.url }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.canGoBack = webView.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.canGoForward = webView.canGoForward }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.isLoading = webView.isLoading }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    DispatchQueue.main.async { self?.parent.estimatedProgress = webView.estimatedProgress }
                }
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loadError = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            show(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            show(error)
        }

        private func show(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.parent.loadError = error.localizedDescription
                self.parent.isLoading = false
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if InAppBrowserManager.canDisplayInApp(requestURL) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url, InAppBrowserManager.canDisplayInApp(url) {
                webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30))
            }
            return nil
        }
    }
}
