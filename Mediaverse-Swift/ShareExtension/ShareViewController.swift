import Security
import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        loadSharedContent()
    }

    private func loadSharedContent() {
        let providers: [NSItemProvider] = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        let imageProviders = Array(providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }.prefix(10))
        if !imageProviders.isEmpty {
            loadImages(from: imageProviders)
            return
        }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                [weak self] item, _ in
                DispatchQueue.main.async { self?.showEcho(url: item as? URL, images: []) }
            }
            return
        }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                [weak self] item, _ in
                let url = (item as? String).flatMap(URL.init(string:))
                DispatchQueue.main.async { self?.showEcho(url: url, images: []) }
            }
            return
        }

        showEcho(url: nil, images: [])
    }

    private func loadImages(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded = [(Int, Data)]()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let image: UIImage?
                if let value = item as? UIImage {
                    image = value
                } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    image = UIImage(data: data)
                } else if let data = item as? Data {
                    image = UIImage(data: data)
                } else {
                    image = nil
                }
                if let image, let data = Self.preparedImageData(image) {
                    lock.lock()
                    loaded.append((index, data))
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.showEcho(url: nil, images: loaded.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }

    private static func preparedImageData(_ source: UIImage) -> Data? {
        let maxBytes = 3_750_000
        var maxPixel: CGFloat = 2048
        var quality: CGFloat = 0.84
        for _ in 0..<6 {
            let largest = max(source.size.width, source.size.height)
            let scale = largest > maxPixel ? maxPixel / largest : 1
            let size = CGSize(
                width: max(1, floor(source.size.width * scale)),
                height: max(1, floor(source.size.height * scale))
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIColor.black.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
                source.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = normalized.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
            quality = max(0.58, quality - 0.07)
            maxPixel *= 0.82
        }
        return nil
    }

    private func showEcho(url: URL?, images: [Data]) {
        let root = ExtensionEchoView(
            sharedURL: url,
            sharedImages: images,
            onClose: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        let host = UIHostingController(
            rootView: root
                .preferredColorScheme(.dark)
                .tint(Color(red: 0, green: 0.90, blue: 0.46))
        )
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
    let sharedImages: [Data]
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
    private var isPhotoRipple: Bool { !sharedImages.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state {
                    case .loading:
                        ProgressView(isPhotoRipple ? "Preparing Ripple…" : "Preparing Echo…")
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
                        message(
                            icon: isPhotoRipple ? "photo.on.rectangle.angled" : "link.badge.plus",
                            title: isPhotoRipple ? "Couldn’t prepare this Ripple" : "Couldn’t prepare this Echo",
                            detail: text
                        )
                    case .ready:
                        previewCard
                        destinationPicker
                        if isPhotoRipple {
                            rippleTextEditor
                        } else {
                            echoMode
                        }
                        publishButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(background)
            .navigationTitle(isPhotoRipple ? "Create Ripple" : "Echo")
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
            Text(isPhotoRipple ? "RIPPLE PREVIEW" : "ECHO PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.46))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider().overlay(.white.opacity(0.07))

            if !sharedImages.isEmpty {
                photoPreview
            } else {
                linkPreview
            }
        }
        .background(surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var photoPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ], spacing: 6) {
                ForEach(Array(sharedImages.prefix(4).enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: sharedImages.count == 1 ? 190 : 108)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .overlay {
                                if index == 3, sharedImages.count > 4 {
                                    Color.black.opacity(0.58)
                                    Text("+\(sharedImages.count - 4)")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .gridCellColumns(sharedImages.count == 1 ? 2 : 1)
                    }
                }
            }
            Label(
                "\(sharedImages.count) photo\(sharedImages.count == 1 ? "" : "s") ready to share",
                systemImage: "photo.on.rectangle.angled"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.66))
        }
        .padding(12)
    }

    private var linkPreview: some View {
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

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let personal = destinations.first(where: \.isPersonal) {
                destinationRow(
                    personal,
                    subtitle: isPhotoRipple ? "Post this Ripple to My Atmo" : "Echo directly to My Atmo"
                )
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

    private var rippleTextEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to your Ripple")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.58))
            TextField(
                "",
                text: $quote,
                prompt: Text("Say something about these photos…").foregroundStyle(.white.opacity(0.42)),
                axis: .vertical
            )
            .foregroundStyle(.white)
            .tint(green)
            .lineLimit(3...8)
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
                publishButtonTitle,
                systemImage: isPhotoRipple ? "wave.3.right" : "dot.radiowaves.left.and.right"
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

    private var publishButtonTitle: String {
        if publishing {
            return isPhotoRipple ? "Publishing Ripple…" : "Echoing…"
        }
        if isPhotoRipple {
            return selected.count > 1 ? "Publish to \(selected.count)" : "Publish Ripple"
        }
        return selected.count > 1 ? "Echo to \(selected.count)" : "Echo"
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
        guard sharedURL != nil || !sharedImages.isEmpty else {
            state = .failed("No shareable link or photo was found.")
            return
        }
        guard ShareAPI.sessionToken != nil else {
            state = .signedOut
            return
        }
        do {
            let vibeData = try await ShareAPI.get("/api/fan-clubs/postable")
            destinations = try JSONDecoder().decode(ShareVibesEnvelope.self, from: vibeData).vibes
            if let sharedURL {
                let resolvedData = try await ShareAPI.post(
                    "/api/fan-clubs/resolve-attachment",
                    body: ["url": sharedURL.absoluteString]
                )
                let object = try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
                guard let rawAttachment = object?["attachment"] as? [String: Any] else {
                    throw ShareAPIError.invalidResponse
                }
                attachment = rawAttachment.mapValues(AnySendable.init)
                if let rawPreview = object?["preview"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: rawPreview) {
                    preview = try? JSONDecoder().decode(SharePreview.self, from: data)
                }
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
        guard !selected.isEmpty, !publishing else { return }
        publishing = true
        do {
            var attachments = [[String: Any]]()
            if !sharedImages.isEmpty, let uploadSlug = selected.sorted().first {
                for photo in sharedImages {
                    let imageURL = try await ShareAPI.uploadPhoto(photo, vibeSlug: uploadSlug)
                    attachments.append(["type": "PHOTO", "imageUrl": imageURL])
                }
            } else if let attachment {
                attachments.append(attachment.mapValues(\.value))
            }
            guard !attachments.isEmpty else { throw ShareAPIError.invalidResponse }
            let body = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            for slug in selected.sorted() {
                var payload: [String: Any] = [
                    "attachments": attachments,
                    "isSpoiler": false,
                    "commentsDisabled": false
                ]
                if (isPhotoRipple || quoteMode), !body.isEmpty { payload["body"] = body }
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
        let query: [String: Any] = [
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

    static func uploadPhoto(_ data: Data, vibeSlug: String) async throws -> String {
        let slug = vibeSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? vibeSlug
        let preparation = try await post(
            "/api/fan-clubs/\(slug)/images/upload-url?purpose=post",
            body: ["mimeType": "image/jpeg", "size": data.count]
        )
        guard let object = try JSONSerialization.jsonObject(with: preparation) as? [String: Any],
              let uploadValue = object["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadValue) else {
            throw ShareAPIError.invalidResponse
        }
        let uploaded = try await upload(data, to: uploadURL)
        let uploadedObject = (try? JSONSerialization.jsonObject(with: uploaded)) as? [String: Any]
        if let value = uploadedObject?["mediaUrl"] as? String, !value.isEmpty { return value }
        if let value = object["mediaUrl"] as? String, !value.isEmpty { return value }
        if let value = object["deliveryUrl"] as? String, !value.isEmpty { return value }
        throw ShareAPIError.invalidResponse
    }

    private static func upload(_ data: Data, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = 120
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        if url.host == baseURL.host, let token = sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "next-auth.session-token=\(token); __Secure-next-auth.session-token=\(token); authjs.session-token=\(token); __Secure-authjs.session-token=\(token)",
                forHTTPHeaderField: "Cookie"
            )
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ShareAPIError.server("The photo could not reach storage.")
        }
        return responseData
    }

    private static func request(_ path: String, method: String, body: Data?) async throws -> Data {
        guard let token = sessionToken,
              let url = endpointURL(path) else {
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

    private static func endpointURL(_ value: String) -> URL? {
        let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawPath = parts.first else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = rawPath.hasPrefix("/") ? String(rawPath) : "/\(rawPath)"
        components?.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        return components?.url
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
