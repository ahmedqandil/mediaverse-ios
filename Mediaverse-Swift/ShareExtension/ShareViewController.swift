import Security
import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        loadSharedURL()
    }

    private func loadSharedURL() {
        let providers: [NSItemProvider] = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                [weak self] item, _ in
                DispatchQueue.main.async { self?.showEcho(url: item as? URL) }
            }
            return
        }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                [weak self] item, _ in
                let url = (item as? String).flatMap(URL.init(string:))
                DispatchQueue.main.async { self?.showEcho(url: url) }
            }
            return
        }

        showEcho(url: nil)
    }

    private func showEcho(url: URL?) {
        let root = ExtensionEchoView(
            sharedURL: url,
            onClose: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ExtensionEchoView: View {
    let sharedURL: URL?
    let onClose: () -> Void

    @State private var state = EchoState.loading
    @State private var destinations: [ShareVibe] = []
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var quote = ""
    @State private var quoteMode = false
    @State private var preview: SharePreview?
    @State private var attachment: [String: AnySendable]?
    @State private var publishing = false
    @FocusState private var focusedField: Field?

    private let green = Color(red: 0, green: 0.90, blue: 0.46)
    private let background = Color(red: 0.03, green: 0.03, blue: 0.06)
    private let surface = Color(red: 0.06, green: 0.06, blue: 0.10)
    private let elevated = Color(red: 0.09, green: 0.10, blue: 0.14)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state {
                    case .loading:
                        ProgressView("Preparing Echo…")
                            .tint(green)
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 90)
                    case .signedOut:
                        message(
                            icon: "person.crop.circle.badge.exclamationmark",
                            title: "Open WeStreem first",
                            detail: "Sign in to WeStreem, then return and share this link again."
                        )
                    case .failed(let text):
                        message(icon: "link.badge.plus", title: "Couldn’t prepare this Echo", detail: text)
                    case .ready:
                        previewCard
                        destinationPicker
                        echoMode
                        publishButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(background)
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: onClose)
                        .foregroundStyle(green)
                }
            }
            .toolbarBackground(surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .tint(green)
        }
        .task { await prepare() }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ECHO PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.46))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().overlay(.white.opacity(0.07))

            HStack(spacing: 12) {
                if let value = preview?.thumbnailUrl, let url = URL(string: value) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        elevated
                    }
                    .frame(width: 118, height: 78)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    Image(systemName: "link")
                        .foregroundStyle(green)
                        .frame(width: 64, height: 64)
                        .background(green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text((preview?.kind ?? "LINK").uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(green)
                    Text(preview?.title ?? sharedURL?.host ?? "Shared link")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(preview?.domain ?? preview?.subtitle ?? sharedURL?.host ?? "WeStreem")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let personal = destinations.first(where: \.isPersonal) {
                destinationRow(personal, subtitle: "Echo directly to My Atmo")
            }

            Text("Find a Vibe")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.58))
            TextField(
                "",
                text: $query,
                prompt: Text("Search by Vibe name").foregroundStyle(.white.opacity(0.42))
            )
                .foregroundStyle(.white)
                .tint(green)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .vibeSearch)
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(focusedField == .vibeSearch ? green.opacity(0.7) : .white.opacity(0.10))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Vibes appear after you start typing.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else if matchingVibes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("No matching Vibes")
                        .font(.subheadline.weight(.semibold))
                    Text("Try a Vibe name or handle.")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(surface.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(matchingVibes) { vibe in
                    destinationRow(vibe, subtitle: nil)
                }
            }

            if !selected.isEmpty {
                Text("\(selected.count) destination\(selected.count == 1 ? "" : "s") selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(green)
            }
        }
    }

    private func destinationRow(_ vibe: ShareVibe, subtitle: String?) -> some View {
        Button {
            if selected.contains(vibe.slug) { selected.remove(vibe.slug) }
            else { selected.insert(vibe.slug) }
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: vibe.avatarUrl.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(elevated)
                        .overlay(Image(systemName: vibe.isPersonal ? "person.fill" : "person.3.fill"))
                }
                .frame(width: 38, height: 38)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.isPersonal ? "My Atmo" : vibe.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.48))
                    }
                }
                Spacer()
                Image(systemName: selected.contains(vibe.slug) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected.contains(vibe.slug) ? green : .white.opacity(0.46))
            }
            .padding(10)
            .background(surface)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var echoMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Echo options")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.58))
            HStack(spacing: 6) {
                echoModeButton("Echo", selected: !quoteMode) { quoteMode = false }
                echoModeButton("Quote Echo", selected: quoteMode) { quoteMode = true }
            }
            .padding(4)
            .background(elevated)
            .clipShape(RoundedRectangle(cornerRadius: 11))

            if quoteMode {
                TextField(
                    "",
                    text: $quote,
                    prompt: Text("Add your take…").foregroundStyle(.white.opacity(0.42)),
                    axis: .vertical
                )
                    .foregroundStyle(.white)
                    .tint(green)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .quote)
                    .padding(14)
                    .frame(minHeight: 112, alignment: .topLeading)
                    .background(elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focusedField == .quote ? green.opacity(0.7) : .white.opacity(0.10))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func echoModeButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(selected ? green : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var publishButton: some View {
        Button {
            Task { await publish() }
        } label: {
            Label(
                publishing ? "Echoing…" : selected.count > 1 ? "Echo to \(selected.count)" : "Echo",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.subheadline.bold())
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(green)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty || publishing)
        .opacity(selected.isEmpty ? 0.5 : 1)
    }

    private var matchingVibes: [ShareVibe] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return [] }
        return destinations.filter {
            !$0.isPersonal && "\($0.name) \($0.slug)".lowercased().contains(value)
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(green)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    @MainActor
    private func prepare() async {
        guard let sharedURL else {
            state = .failed("No shareable link was found.")
            return
        }
        guard ShareAPI.sessionToken != nil else {
            state = .signedOut
            return
        }
        do {
            async let vibeRequest = ShareAPI.get("/api/fan-clubs/postable")
            async let resolveRequest = ShareAPI.post(
                "/api/fan-clubs/resolve-attachment",
                body: ["url": sharedURL.absoluteString]
            )
            let vibeData = try await vibeRequest
            let resolvedData = try await resolveRequest
            destinations = try JSONDecoder().decode(ShareVibesEnvelope.self, from: vibeData).vibes
            let object = try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
            guard let rawAttachment = object?["attachment"] as? [String: Any] else {
                throw ShareAPIError.invalidResponse
            }
            attachment = rawAttachment.mapValues(AnySendable.init)
            if let rawPreview = object?["preview"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: rawPreview) {
                preview = try? JSONDecoder().decode(SharePreview.self, from: data)
            }
            if let personal = destinations.first(where: \.isPersonal) {
                selected.insert(personal.slug)
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func publish() async {
        guard let attachment, !selected.isEmpty, !publishing else { return }
        publishing = true
        do {
            let body = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            for slug in selected.sorted() {
                var payload: [String: Any] = [
                    "attachments": [attachment.mapValues(\.value)],
                    "isSpoiler": false,
                    "commentsDisabled": false
                ]
                if quoteMode, !body.isEmpty { payload["body"] = body }
                _ = try await ShareAPI.post(
                    "/api/fan-clubs/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/posts",
                    body: payload
                )
            }
            onClose()
        } catch {
            state = .failed(error.localizedDescription)
        }
        publishing = false
    }
}

private enum Field: Hashable {
    case vibeSearch
    case quote
}

private enum EchoState: Equatable {
    case loading
    case ready
    case signedOut
    case failed(String)
}

private struct ShareVibesEnvelope: Decodable { let vibes: [ShareVibe] }
private struct ShareVibe: Decodable, Identifiable {
    let slug: String
    let name: String
    let avatarUrl: String?
    let isPersonal: Bool
    var id: String { slug }
}
private struct SharePreview: Decodable {
    let kind: String?
    let title: String?
    let subtitle: String?
    let thumbnailUrl: String?
    let domain: String?
}
private struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

private enum ShareAPI {
    static let baseURL = URL(string: "https://www.westreem.com")!
    static let keychainGroup = "LPXBZ2LJZ8.com.westreem.shared"
    static let service = "com.westreem.mediaverse.session"
    static let account = "westreem.sessionJWT"

    static var sessionToken: String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func get(_ path: String) async throws -> Data {
        try await request(path, method: "GET", body: nil)
    }

    static func post(_ path: String, body: [String: Any]) async throws -> Data {
        try await request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    private static func request(_ path: String, method: String, body: Data?) async throws -> Data {
        guard let token = sessionToken,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw ShareAPIError.signedOut
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-Westreem-Platform")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "next-auth.session-token=\(token); __Secure-next-auth.session-token=\(token); authjs.session-token=\(token); __Secure-authjs.session-token=\(token)",
            forHTTPHeaderField: "Cookie"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ShareAPIError.server(message ?? "WeStreem returned \(http.statusCode).")
        }
        return data
    }
}

private enum ShareAPIError: LocalizedError {
    case signedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Open WeStreem and sign in first."
        case .invalidResponse: "WeStreem returned an invalid response."
        case .server(let message): message
        }
    }
}
