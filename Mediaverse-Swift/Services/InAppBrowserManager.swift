import SwiftUI
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
        C.isTrustedBrowserURL(url)
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
    @State private var navigationAction: InAppBrowserNavigationAction?

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
                    navigationAction: $navigationAction
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading {
                    ProgressView()
                        .tint(C.watch)
                        .padding(.top, 8)
                }
            }
            .navigationTitle(title.isEmpty ? displayHost : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(C.watch)
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

                    Text((currentURL ?? url).host(percentEncoded: false) ?? displayHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        navigationAction = .reload
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var displayHost: String {
        url.host(percentEncoded: false) ?? "Browser"
    }
}

enum InAppBrowserNavigationAction: Equatable {
    case back
    case forward
    case reload
}

private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @Binding var title: String
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
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
                webView.reload()
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
                }
            ]
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
