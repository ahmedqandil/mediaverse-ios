import SwiftUI

struct MentionSearchResult: Codable, Identifiable, Equatable {
    let type: String
    let id: String
    let handle: String
    let displayName: String
    let avatarUrl: String?
}

struct MentionSearchResponse: Codable {
    let results: [MentionSearchResult]
}

@MainActor
enum MentionParser {
    private static var resultsByHandle = [String: MentionSearchResult]()
    private static var unresolvedHandles = Set<String>()

    static func activeQuery(in text: String) -> (query: String, tokenStart: String.Index)? {
        let pattern = #"@([a-zA-Z][a-zA-Z0-9_]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let queryRange = Range(match.range(at: 1), in: text),
              let fullRange = Range(match.range, in: text) else {
            return nil
        }
        return (String(text[queryRange]), fullRange.lowerBound)
    }

    static func remember(_ result: MentionSearchResult) {
        let normalized = result.handle.lowercased()
        resultsByHandle[normalized] = result
        unresolvedHandles.remove(normalized)
    }

    static func remember(handle: String, displayName: String) {
        remember(MentionSearchResult(type: "user", id: handle, handle: handle, displayName: displayName, avatarUrl: nil))
    }

    static func rememberUnresolved(handle: String) {
        unresolvedHandles.insert(handle.lowercased())
    }

    static func cachedResult(for handle: String) -> MentionSearchResult? {
        resultsByHandle[handle.lowercased()]
    }

    static func hasDisplayName(for handle: String) -> Bool {
        cachedResult(for: handle)?.displayName != nil
    }

    static func isKnownUnresolved(_ handle: String) -> Bool {
        unresolvedHandles.contains(handle.lowercased())
    }

    static func handles(in text: String?) -> [String] {
        guard let text, let regex = try? NSRegularExpression(pattern: #"@([a-zA-Z][a-zA-Z0-9_]{1,29})"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let handleRange = Range(match.range(at: 1), in: text) else { return nil }
            let handle = String(text[handleRange]).lowercased()
            return seen.insert(handle).inserted ? handle : nil
        }
    }

    static func insert(handle: String, into text: inout String) {
        guard let active = activeQuery(in: text) else { return }
        text.replaceSubrange(active.tokenStart..<text.endIndex, with: "@\(handle) ")
    }

    static func attributedText(plain: String?, html: String?) -> AttributedString {
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return attributedHTML(html)
        }
        return attributedPlainText(plain ?? "")
    }

    private static func attributedPlainText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let regex = try? NSRegularExpression(pattern: #"@([a-zA-Z][a-zA-Z0-9_]{1,29})"#) else {
            return attributed
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange).reversed() {
            guard let range = Range(match.range, in: text),
                  let handleRange = Range(match.range(at: 1), in: text),
                  let attrRange = Range(range, in: attributed) else { continue }

            let handle = String(text[handleRange]).lowercased()
            let displayName = cachedResult(for: handle)?.displayName
            if let displayName, !displayName.isEmpty {
                var replacement = AttributedString(displayName)
                styleMention(&replacement, handle: handle)
                attributed.replaceSubrange(attrRange, with: replacement)
            } else {
                attributed[attrRange].foregroundColor = C.watch
                attributed[attrRange].link = mentionURL(for: handle)
            }
        }
        return attributed
    }

    private static func attributedHTML(_ html: String) -> AttributedString {
        guard let regex = try? NSRegularExpression(pattern: #"<a\b([^>]*)>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return AttributedString(displayText(fromHTML: html))
        }

        var output = AttributedString()
        var cursor = html.startIndex
        let nsRange = NSRange(html.startIndex..., in: html)

        for match in regex.matches(in: html, range: nsRange) {
            guard let fullRange = Range(match.range, in: html),
                  let attrsRange = Range(match.range(at: 1), in: html),
                  let labelRange = Range(match.range(at: 2), in: html) else { continue }

            if cursor < fullRange.lowerBound {
                output += AttributedString(displayText(fromHTML: String(html[cursor..<fullRange.lowerBound])))
            }

            let attrs = String(html[attrsRange])
            let label = displayText(fromHTML: String(html[labelRange]))
            var mention = AttributedString(label)
            if let handle = mentionHandle(fromAnchorAttributes: attrs) {
                styleMention(&mention, handle: handle)
            }
            output += mention
            cursor = fullRange.upperBound
        }

        if cursor < html.endIndex {
            output += AttributedString(displayText(fromHTML: String(html[cursor..<html.endIndex])))
        }
        return output
    }

    private static func mentionHandle(fromAnchorAttributes attrs: String) -> String? {
        let patterns = [
            #"data-handle=[\"']@?([a-zA-Z][a-zA-Z0-9_]{1,29})[\"']"#,
            #"href=[\"'][^\"']*/u/([a-zA-Z][a-zA-Z0-9_]{1,29})[^\"']*[\"']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(attrs.startIndex..., in: attrs)
            guard let match = regex.firstMatch(in: attrs, range: range),
                  let handleRange = Range(match.range(at: 1), in: attrs) else { continue }
            return String(attrs[handleRange]).lowercased()
        }
        return nil
    }

    private static func styleMention(_ attributed: inout AttributedString, handle: String) {
        attributed.foregroundColor = C.watch
        attributed.link = mentionURL(for: handle)
    }

    static func mentionURL(for handle: String) -> URL? {
        URL(string: "westreem-mention://\(handle.lowercased())")
    }

    private static func displayText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(text)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

struct MentionText: View {
    let plain: String?
    let html: String?
    var font: Font = .system(size: 13)
    var color: Color = C.text

    @Environment(\.openURL) private var openURL
    @State private var renderVersion = 0

    private var resolutionKey: String {
        "\(plain ?? "")|\(html ?? "")"
    }

    var body: some View {
        Text(MentionParser.attributedText(plain: plain, html: html))
            .font(font)
            .foregroundStyle(color)
            .id(renderVersion)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "westreem-mention", let handle = url.host, !handle.isEmpty else {
                    return .systemAction
                }
                Task { await navigateToMention(handle: handle) }
                return .handled
            })
            .task(id: resolutionKey) {
                await resolveExistingMentionsIfNeeded()
            }
    }

    @MainActor
    private func resolveExistingMentionsIfNeeded() async {
        let handles = handlesToResolve()
        guard !handles.isEmpty else { return }

        var didResolve = false
        for handle in handles {
            if let result = await resolveMention(handle: handle) {
                MentionParser.remember(result)
                didResolve = true
            } else {
                MentionParser.rememberUnresolved(handle: handle)
            }
        }

        if didResolve {
            renderVersion += 1
        }
    }

    @MainActor
    private func handlesToResolve() -> [String] {
        guard html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return [] }
        return MentionParser.handles(in: plain).filter { handle in
            !MentionParser.hasDisplayName(for: handle) && !MentionParser.isKnownUnresolved(handle)
        }
    }

    private func resolveMention(handle: String) async -> MentionSearchResult? {
        if let cached = await MainActor.run(body: { MentionParser.cachedResult(for: handle) }) {
            return cached
        }
        do {
            let response = try await APIClient.shared.searchMentions(q: handle, limit: 6)
            return response.results.first { $0.handle.lowercased() == handle.lowercased() }
        } catch {
            return nil
        }
    }

    @MainActor
    private func navigateToMention(handle: String) async {
        guard let result = await resolveMention(handle: handle) else {
            openMentionFallback(handle: handle)
            return
        }
        MentionParser.remember(result)

        switch result.type.lowercased() {
        case "channel":
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: AppRoute.channel(result.handle))
        case "show":
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: AppRoute.show(result.id))
        default:
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: AppRoute.channel(result.handle))
        }
    }

    @MainActor
    private func openMentionFallback(handle: String) {
        NotificationCenter.default.post(name: .mentionNavigationRequested, object: AppRoute.channel(handle))
    }
}

struct MentionAutocompletePanel: View {
    @Binding var text: String
    var limit: Int = 6
    var minimumQueryLength: Int = 2
    var onSelect: ((MentionSearchResult) -> Void)? = nil

    @State private var results = [MentionSearchResult]()
    @State private var searchTask: Task<Void, Never>?
    @State private var isLoading = false

    private var query: String? {
        MentionParser.activeQuery(in: text)?.query
    }

    var body: some View {
        Group {
            if shouldShowPanel {
                VStack(alignment: .leading, spacing: 0) {
                    if let query, query.count < minimumQueryLength {
                        mentionStatusRow("Keep typing to search mentions")
                    } else if isLoading && results.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().tint(C.watch)
                            Text("Searching mentions...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(C.textMuted)
                            Spacer()
                        }
                        .padding(10)
                    } else if results.isEmpty {
                        mentionStatusRow("No mentions found")
                    } else {
                        ForEach(results) { result in
                            Button {
                                MentionParser.remember(result)
                                if let onSelect {
                                    onSelect(result)
                                } else {
                                    MentionParser.insert(handle: result.handle, into: &text)
                                }
                                results = []
                            } label: {
                                mentionRow(result)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
                .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: query ?? "") { _, newValue in
            scheduleSearch(newValue)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var shouldShowPanel: Bool {
        query != nil
    }

    private func mentionStatusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "at")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(C.watch)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(C.textMuted)
            Spacer()
        }
        .padding(10)
    }

    private func mentionRow(_ result: MentionSearchResult) -> some View {
        HStack(spacing: 10) {
            CachedRemoteImage(
                url: C.mediaURL(result.avatarUrl),
                targetSize: CGSize(width: 34, height: 34)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle()
                    .fill(C.surface)
                    .overlay {
                        Text(String(result.displayName.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(C.textMuted)
                    }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(1)
                Text("@\(result.handle) · \(result.type.capitalized)")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        guard query.count >= minimumQueryLength else {
            results = []
            isLoading = false
            return
        }
        isLoading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                let response = try await APIClient.shared.searchMentions(q: query, limit: limit)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    results = response.results
                    for result in response.results {
                        MentionParser.remember(result)
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    results = []
                    isLoading = false
                }
            }
        }
    }
}
