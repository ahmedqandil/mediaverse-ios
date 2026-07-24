import SwiftUI
import UIKit

struct StoryOverlayLayout {
    static let minimumScale = 0.25
    static let maximumScale = 4.0
    static let safeBounds = CGRect(x: 0.04, y: 0.12, width: 0.92, height: 0.70)

    static func normalizedBase(from transform: Transform2D, canvas: CanvasSpec) -> StoryOverlayBase {
        let width = Double(max(canvas.width, 1))
        let height = Double(max(canvas.height, 1))
        let sanitized = sanitizedTransform(transform)
        return StoryOverlayBase(
            x: clamp01(0.5 + sanitized.tx / width),
            y: clamp01(0.5 - sanitized.ty / height),
            scale: sanitized.scale,
            rotation: normalizedDegrees(sanitized.rotation * 180 / .pi)
        )
    }

    static func position(for base: StoryOverlayBase, in viewportSize: CGSize) -> CGPoint {
        CGPoint(x: base.x * viewportSize.width, y: base.y * viewportSize.height)
    }

    static func position(for base: StoryOverlayBase, canvas: CanvasSpec, in viewportSize: CGSize) -> CGPoint {
        let frame = storyFrame(for: canvas, in: viewportSize)
        return CGPoint(
            x: frame.minX + base.x * frame.width,
            y: frame.minY + base.y * frame.height
        )
    }

    static func position(for transform: Transform2D, canvas: CanvasSpec, in viewportSize: CGSize) -> CGPoint {
        position(for: normalizedBase(from: transform, canvas: canvas), canvas: canvas, in: viewportSize)
    }

    static func viewportScale(for canvas: CanvasSpec, in viewportSize: CGSize) -> CGSize {
        let frame = storyFrame(for: canvas, in: viewportSize)
        return CGSize(
            width: frame.width / CGFloat(max(canvas.width, 1)),
            height: frame.height / CGFloat(max(canvas.height, 1))
        )
    }

    static func stickerPresentationScale(for canvas: CanvasSpec, in viewportSize: CGSize) -> CGFloat {
        let frame = storyFrame(for: canvas, in: viewportSize)
        let referenceWidth: CGFloat = 390
        return frame.width / referenceWidth
    }

    static func storyFrame(for canvas: CanvasSpec, in viewportSize: CGSize) -> CGRect {
        let canvasSize = CGSize(
            width: max(1, CGFloat(canvas.width)),
            height: max(1, CGFloat(canvas.height))
        )
        let scale = min(
            viewportSize.width / canvasSize.width,
            viewportSize.height / canvasSize.height
        )
        let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: (viewportSize.width - size.width) / 2,
            y: (viewportSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func safeFrame(for canvas: CanvasSpec, in viewportSize: CGSize) -> CGRect {
        let frame = storyFrame(for: canvas, in: viewportSize)
        return CGRect(
            x: frame.minX + frame.width * safeBounds.minX,
            y: frame.minY + frame.height * safeBounds.minY,
            width: frame.width * safeBounds.width,
            height: frame.height * safeBounds.height
        )
    }

    static func estimatedStickerSize(for overlay: StoryInteractiveOverlay) -> CGSize {
        switch overlay.kind {
        case .link:
            return CGSize(width: max(118, min(260, CGFloat(overlay.title.count) * 8 + 76)), height: 46)
        case .mention:
            return CGSize(width: max(118, min(240, CGFloat(overlay.title.count) * 8 + 76)), height: 46)
        case .location:
            return CGSize(width: max(96, min(260, CGFloat(overlay.title.count) * 8 + 44)), height: 34)
        case .countdown:
            return CGSize(width: 132, height: 64)
        case .poll, .quiz:
            let optionCount = overlay.options.filter { !$0.contains("=") }.count
            return CGSize(width: 260, height: CGFloat(56 + max(optionCount, 2) * 46))
        case .question:
            return CGSize(width: 240, height: 110)
        case .addYours, .avatar:
            return CGSize(width: 220, height: 92)
        }
    }

    static func safeNormalizedBase(for overlay: StoryInteractiveOverlay, canvas: CanvasSpec) -> StoryOverlayBase {
        let canonicalViewport = CGSize(width: 390, height: 844)
        let transform = clampedInteractiveTransform(
            overlay.transform,
            stickerSize: estimatedStickerSize(for: overlay),
            canvas: canvas,
            viewportSize: canonicalViewport
        )
        return normalizedBase(from: transform, canvas: canvas)
    }

    static func clampedBase(
        _ base: StoryOverlayBase,
        stickerSize: CGSize,
        canvas: CanvasSpec,
        viewportSize: CGSize
    ) -> StoryOverlayBase {
        let transform = clampedInteractiveTransform(
            transform(from: sanitizedBase(base), canvas: canvas),
            stickerSize: stickerSize,
            canvas: canvas,
            viewportSize: viewportSize
        )
        return normalizedBase(from: transform, canvas: canvas)
    }

    static func estimatedStickerSize(for overlay: StoryOverlay) -> CGSize {
        switch overlay {
        case .link(_, let data):
            return CGSize(width: max(118, min(260, CGFloat((data.label ?? data.url).count) * 8 + 76)), height: 46)
        case .mention(_, let data):
            return CGSize(width: max(118, min(240, CGFloat(data.displayName.count) * 8 + 76)), height: 46)
        case .location(_, let data):
            return CGSize(width: max(96, min(260, CGFloat(data.name.count) * 8 + 44)), height: 34)
        case .countdown:
            return CGSize(width: 132, height: 64)
        case .poll(_, let data):
            return CGSize(width: 260, height: CGFloat(56 + max(data.options.count, 2) * 46))
        case .quiz(_, let data):
            return CGSize(width: 260, height: CGFloat(56 + max(data.options.count, 2) * 46))
        case .question:
            return CGSize(width: 240, height: 110)
        case .unknown:
            return CGSize(width: 220, height: 92)
        }
    }

    static func transform(from base: StoryOverlayBase, canvas: CanvasSpec) -> Transform2D {
        let width = Double(max(canvas.width, 1))
        let height = Double(max(canvas.height, 1))
        return sanitizedTransform(
            Transform2D(
                scale: base.scale ?? 1,
                rotation: (base.rotation ?? 0) * .pi / 180,
                tx: (clamp01(base.x) - 0.5) * width,
                ty: (0.5 - clamp01(base.y)) * height
            )
        )
    }

    static func clampedInteractiveTransform(
        _ transform: Transform2D,
        stickerSize: CGSize,
        canvas: CanvasSpec,
        viewportSize: CGSize
    ) -> Transform2D {
        let frame = storyFrame(for: canvas, in: viewportSize)
        guard frame.width > 0, frame.height > 0 else {
            return sanitizedTransform(transform)
        }

        var sanitized = sanitizedTransform(transform)
        let presentationScale = stickerPresentationScale(for: canvas, in: viewportSize)
        let baseWidth = max(stickerSize.width * presentationScale, 1)
        let baseHeight = max(stickerSize.height * presentationScale, 1)
        let safeFrame = safeFrame(for: canvas, in: viewportSize)

        let cosine = abs(cos(CGFloat(sanitized.rotation)))
        let sine = abs(sin(CGFloat(sanitized.rotation)))
        let rotatedBaseWidth = baseWidth * cosine + baseHeight * sine
        let rotatedBaseHeight = baseWidth * sine + baseHeight * cosine
        let maximumFittingScale = min(
            safeFrame.width / max(rotatedBaseWidth, 1),
            safeFrame.height / max(rotatedBaseHeight, 1)
        )
        sanitized.scale = min(sanitized.scale, max(minimumScale, Double(maximumFittingScale)))

        let halfWidth = rotatedBaseWidth * CGFloat(sanitized.scale) / 2
        let halfHeight = rotatedBaseHeight * CGFloat(sanitized.scale) / 2
        let proposedCenter = position(for: sanitized, canvas: canvas, in: viewportSize)
        let minimumX = safeFrame.minX + halfWidth
        let maximumX = safeFrame.maxX - halfWidth
        let minimumY = safeFrame.minY + halfHeight
        let maximumY = safeFrame.maxY - halfHeight
        let clampedCenter = CGPoint(
            x: minimumX <= maximumX ? min(max(proposedCenter.x, minimumX), maximumX) : safeFrame.midX,
            y: minimumY <= maximumY ? min(max(proposedCenter.y, minimumY), maximumY) : safeFrame.midY
        )
        let normalizedX = (clampedCenter.x - frame.minX) / frame.width
        let normalizedY = (clampedCenter.y - frame.minY) / frame.height
        sanitized.tx = Double(normalizedX - 0.5) * Double(max(canvas.width, 1))
        sanitized.ty = Double(0.5 - normalizedY) * Double(max(canvas.height, 1))
        return sanitized
    }

    static func sanitizedBase(_ base: StoryOverlayBase) -> StoryOverlayBase {
        StoryOverlayBase(
            x: clamp01(finite(base.x, fallback: 0.5)),
            y: clamp01(finite(base.y, fallback: 0.5)),
            scale: min(max(finite(base.scale ?? 1, fallback: 1), minimumScale), maximumScale),
            rotation: normalizedDegrees(finite(base.rotation ?? 0, fallback: 0))
        )
    }

    private static func sanitizedTransform(_ transform: Transform2D) -> Transform2D {
        Transform2D(
            scale: min(max(finite(transform.scale, fallback: 1), minimumScale), maximumScale),
            rotation: finite(transform.rotation, fallback: 0),
            tx: finite(transform.tx, fallback: 0),
            ty: finite(transform.ty, fallback: 0)
        )
    }

    private static func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized < -180 ? normalized + 360 : (normalized > 180 ? normalized - 360 : normalized)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct StoryOverlayStickerView: View {
    let overlay: StoryOverlay
    var storyId: String?
    var overlayIndex: Int = 0
    var isInteractive: Bool = true
    var onMentionNavigate: () -> Void = {}
    var setPaused: (Bool) -> Void = { _ in }

    var body: some View {
        switch overlay {
        case .mention(_, let data):
            MentionStorySticker(data: data, isInteractive: isInteractive, onNavigate: onMentionNavigate)
        case .location(_, let data):
            LocationStorySticker(data: data, isInteractive: isInteractive)
        case .poll(_, let data):
            PollStorySticker(data: data, storyId: storyId, overlayIndex: overlayIndex, isInteractive: isInteractive)
        case .quiz(_, let data):
            QuizStorySticker(data: data, storyId: storyId, overlayIndex: overlayIndex, isInteractive: isInteractive)
        case .countdown(_, let data):
            CountdownStorySticker(data: data)
        case .link(_, let data):
            LinkStorySticker(data: data, isInteractive: isInteractive)
        case .question(_, let data):
            QuestionStorySticker(data: data, storyId: storyId, overlayIndex: overlayIndex, isInteractive: isInteractive, setPaused: setPaused)
        case .unknown:
            EmptyView()
        }
    }
}

extension StoryOverlay {
    static func editorPreview(from overlay: StoryInteractiveOverlay, canvas: CanvasSpec) -> StoryOverlay {
        let base = StoryOverlayLayout.normalizedBase(from: overlay.transform, canvas: canvas)
        let metadata = Self.optionDictionary(overlay.options)
        let visibleOptions = Self.visibleOptions(overlay.options)

        switch overlay.kind {
        case .link:
            return .link(
                base: base,
                data: LinkOverlayData(
                    url: metadata["url"] ?? overlay.subtitle ?? "",
                    label: overlay.title
                )
            )
        case .mention:
            let handle = metadata["handle"] ?? overlay.subtitle?.replacingOccurrences(of: "@", with: "") ?? overlay.title
            return .mention(
                base: base,
                data: MentionOverlayData(
                    entityType: metadata["type"] ?? "user",
                    entityId: metadata["entityId"] ?? handle,
                    handle: handle,
                    displayName: overlay.title,
                    avatarUrl: metadata["avatarUrl"]
                )
            )
        case .location:
            return .location(
                base: base,
                data: LocationOverlayData(
                    name: overlay.title,
                    lat: Double(metadata["lat"] ?? ""),
                    lng: Double(metadata["lng"] ?? "")
                )
            )
        case .poll:
            return .poll(
                base: base,
                data: PollOverlayData(question: overlay.title, options: visibleOptions, votes: nil, totalVotes: nil, userVote: nil)
            )
        case .quiz:
            let correctIndex = min(max(Int(metadata["correctIndex"] ?? "") ?? 0, 0), max(visibleOptions.count - 1, 0))
            return .quiz(
                base: base,
                data: QuizOverlayData(question: overlay.title, options: visibleOptions, correctIndex: correctIndex, userAnswer: nil, isCorrect: nil)
            )
        case .question:
            return .question(
                base: base,
                data: QuestionOverlayData(prompt: overlay.title, replyCount: nil, userReplied: nil)
            )
        case .countdown:
            return .countdown(
                base: base,
                data: CountdownOverlayData(label: overlay.title, endsAt: overlay.targetDate ?? Date().addingTimeInterval(60))
            )
        case .addYours, .avatar:
            return .question(
                base: base,
                data: QuestionOverlayData(prompt: overlay.title, replyCount: nil, userReplied: nil)
            )
        }
    }

    private static func optionDictionary(_ options: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: options.compactMap { value in
            guard let separator = value.firstIndex(of: "=") else { return nil }
            let key = String(value[..<separator])
            let rawValue = String(value[value.index(after: separator)...])
            return (key, rawValue)
        })
    }

    private static func visibleOptions(_ options: [String]) -> [String] {
        let filtered = options.filter { !$0.contains("=") }
        return filtered.isEmpty ? ["Yes", "No"] : filtered
    }
}

private struct StoryStickerBacking: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.86))
            .shadow(color: C.watch.opacity(0.16), radius: 12, y: 4)
    }
}

private struct MentionStorySticker: View {
    let data: MentionOverlayData
    let isInteractive: Bool
    var onNavigate: () -> Void

    var body: some View {
        Button {
            guard isInteractive else { return }
            navigate()
        } label: {
            HStack(spacing: 6) {
                if let avatarStr = data.avatarUrl, let url = C.mediaURL(avatarStr) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: 22, height: 22)
                    ) { img in img.resizable().scaledToFill() } placeholder: {
                        avatarFallback
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                } else {
                    avatarFallback
                }
                Text("@\(data.handle)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StoryStickerBacking())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
    }

    private var avatarFallback: some View {
        Circle()
            .fill(C.watch)
            .frame(width: 22, height: 22)
            .overlay {
                Text(String(data.displayName.prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
            }
    }

    private func navigate() {
        let route: AppRoute
        switch data.entityType.lowercased() {
        case "channel": route = .channel(data.handle.isEmpty ? data.entityId : data.handle)
        case "show": route = .show(data.entityId)
        default: route = .channel(data.handle.isEmpty ? data.entityId : data.handle)
        }
        onNavigate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .mentionNavigationRequested, object: route)
        }
    }
}

private struct LocationStorySticker: View {
    let data: LocationOverlayData
    let isInteractive: Bool

    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    var body: some View {
        Button {
            guard isInteractive else { return }
            openInMaps()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(C.watch)
                Text(data.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StoryStickerBacking())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
    }

    private func openInMaps() {
        guard let lat = data.lat, let lng = data.lng else { return }
        let encoded = data.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://maps.apple.com/?q=\(encoded)&ll=\(lat),\(lng)") else { return }
        inAppBrowser.open(url)
    }
}

private struct PollStorySticker: View {
    let data: PollOverlayData
    let storyId: String?
    let overlayIndex: Int
    let isInteractive: Bool

    @State private var votes: [Int]
    @State private var userVote: Int?
    @State private var isSubmitting = false

    init(data: PollOverlayData, storyId: String?, overlayIndex: Int, isInteractive: Bool) {
        self.data = data
        self.storyId = storyId
        self.overlayIndex = overlayIndex
        self.isInteractive = isInteractive
        _votes = State(initialValue: Self.normalizedVotes(data.votes, optionCount: data.options.count))
        _userVote = State(initialValue: data.userVote)
    }

    private var totalVotes: Int { votes.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(data.question)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)

            ForEach(data.options.indices, id: \.self) { index in
                Button { vote(for: index) } label: {
                    pollOption(index: index)
                }
                .buttonStyle(.plain)
                .disabled(!isInteractive || isSubmitting)
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(StoryStickerBacking())
    }

    private func pollOption(index: Int) -> some View {
        let isSelected = userVote == index
        let percent = totalVotes > 0 && votes.indices.contains(index) ? Double(votes[index]) / Double(totalVotes) : 0
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(C.watch.opacity(0.18))
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? C.watch.opacity(0.65) : C.watch.opacity(0.30))
                    .frame(width: userVote != nil ? proxy.size.width * percent : 0)
                    .animation(.easeOut(duration: 0.28), value: percent)
            }
            .frame(height: 38)
            HStack {
                Text(data.options[index])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if userVote != nil {
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }

    private func vote(for optionIndex: Int) {
        guard isInteractive, let storyId, !isSubmitting, votes.indices.contains(optionIndex) else { return }
        let previousVote = userVote
        let previousVotes = votes
        if let previousVote, votes.indices.contains(previousVote) {
            votes[previousVote] = max(0, votes[previousVote] - 1)
        }
        votes[optionIndex] += 1
        userVote = optionIndex
        isSubmitting = true

        Task {
            do {
                let response = try await StoriesAPIClient.shared.pollVote(storyId: storyId, overlayIndex: overlayIndex, optionIndex: optionIndex)
                await MainActor.run {
                    votes = Self.normalizedVotes(response.votes, optionCount: data.options.count)
                    userVote = response.userVote
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    votes = previousVotes
                    userVote = previousVote
                    isSubmitting = false
                }
            }
        }
    }

    private static func normalizedVotes(_ votes: [Int]?, optionCount: Int) -> [Int] {
        var normalized = votes ?? []
        if normalized.count < optionCount {
            normalized.append(contentsOf: Array(repeating: 0, count: optionCount - normalized.count))
        }
        return Array(normalized.prefix(optionCount))
    }
}

private struct QuizStorySticker: View {
    let data: QuizOverlayData
    let storyId: String?
    let overlayIndex: Int
    let isInteractive: Bool

    @State private var userAnswer: Int?
    @State private var correctIndex: Int
    @State private var isSubmitting = false

    init(data: QuizOverlayData, storyId: String?, overlayIndex: Int, isInteractive: Bool) {
        self.data = data
        self.storyId = storyId
        self.overlayIndex = overlayIndex
        self.isInteractive = isInteractive
        _userAnswer = State(initialValue: data.userAnswer)
        _correctIndex = State(initialValue: data.correctIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(C.watch)
                    .font(.system(size: 12))
                Text("QUIZ")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(C.watch)
            }
            Text(data.question)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
            ForEach(data.options.indices, id: \.self) { index in
                Button { submit(selectedIndex: index) } label: {
                    optionRow(index: index)
                }
                .buttonStyle(.plain)
                .disabled(!isInteractive || userAnswer != nil || isSubmitting)
            }
        }
        .padding(12)
        .frame(minWidth: 200, maxWidth: 260)
        .background(StoryStickerBacking())
    }

    private func optionRow(index: Int) -> some View {
        let answered = userAnswer != nil
        let isCorrect = index == correctIndex
        let isChosen = userAnswer == index
        return HStack {
            Text(data.options[index])
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if answered {
                if isCorrect {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(C.watch)
                } else if isChosen {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.78))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(optionBackground(index: index)))
        .animation(.easeOut(duration: 0.25), value: answered)
    }

    private func optionBackground(index: Int) -> Color {
        guard let userAnswer else { return C.watch.opacity(0.14) }
        if index == correctIndex { return C.watch.opacity(0.55) }
        if index == userAnswer { return Color.black.opacity(0.92) }
        return C.watch.opacity(0.14)
    }

    private func submit(selectedIndex: Int) {
        guard isInteractive, let storyId, userAnswer == nil, !isSubmitting else { return }
        userAnswer = selectedIndex
        isSubmitting = true
        Task {
            do {
                let response = try await StoriesAPIClient.shared.quizAnswer(storyId: storyId, overlayIndex: overlayIndex, selectedIndex: selectedIndex)
                await MainActor.run {
                    userAnswer = response.selectedIndex
                    correctIndex = response.correctIndex
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    userAnswer = nil
                    isSubmitting = false
                }
            }
        }
    }
}

private struct CountdownStorySticker: View {
    let data: CountdownOverlayData

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            Text(data.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
            Text(timeString)
                .font(.system(size: 22, weight: .black).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(StoryStickerBacking())
        .onReceive(timer) { t in now = t }
    }

    private var timeString: String {
        let remaining = max(data.endsAt.timeIntervalSince(now), 0)
        if remaining <= 0 { return "00:00:00" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct LinkStorySticker: View {
    let data: LinkOverlayData
    let isInteractive: Bool

    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    var body: some View {
        Button {
            guard isInteractive, let url = URL(string: data.url) else { return }
            inAppBrowser.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
                Text(data.label ?? data.url)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(StoryStickerBacking())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
    }
}

private struct QuestionStorySticker: View {
    let data: QuestionOverlayData
    let storyId: String?
    let overlayIndex: Int
    let isInteractive: Bool
    var setPaused: (Bool) -> Void

    @State private var draft = ""
    @State private var showReplySheet = false

    var body: some View {
        Button {
            guard isInteractive else { return }
            setPaused(true)
            showReplySheet = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(C.watch)
                    Text("ASK ME")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(C.watch)
                }
                Text(data.prompt)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(minWidth: 180, maxWidth: 240)
            .background(StoryStickerBacking())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .sheet(isPresented: $showReplySheet, onDismiss: { setPaused(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(data.prompt)
                    .font(.system(size: 18, weight: .bold))
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { sendReply() }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
            .presentationDetents([.medium])
        }
    }

    private func sendReply() {
        guard let storyId else { return }
        let reply = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        Task {
            _ = try? await StoriesAPIClient.shared.questionReply(storyId: storyId, overlayIndex: overlayIndex, text: reply)
            await MainActor.run {
                draft = ""
                showReplySheet = false
            }
        }
    }
}
