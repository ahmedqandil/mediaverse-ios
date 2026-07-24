import SwiftUI

@MainActor
final class StoryViewersViewModel: ObservableObject {
    @Published private(set) var viewers: [StoryViewer] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published var error: String?

    private(set) var nextCursor: String?
    private var didLoad = false
    private let storyId: String
    private let apiClient: StoriesAPIClient

    init(storyId: String, apiClient: StoriesAPIClient = .shared, initialResponse: StoryViewersResponse? = nil) {
        self.storyId = storyId
        self.apiClient = apiClient
        if let initialResponse {
            apply(initialResponse, cursor: nil)
            didLoad = true
        }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func refresh() async {
        didLoad = false
        nextCursor = nil
        await load()
    }

    func loadMore() async {
        guard nextCursor != nil, !isLoading else { return }
        await load(cursor: nextCursor)
    }

    private func load(cursor: String? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response = try await apiClient.fetchViewers(storyId: storyId, cursor: cursor)
            apply(response, cursor: cursor)
            didLoad = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ response: StoryViewersResponse, cursor: String?) {
        total = response.total
        nextCursor = response.nextCursor
        viewers = cursor == nil ? response.viewers : viewers + response.viewers
    }
}

struct ViewersSheet: View {
    @StateObject var viewModel: StoryViewersViewModel
    let story: StoryItem

    @State private var tab: SheetTab = .viewers

    enum SheetTab: String, CaseIterable {
        case viewers = "Viewers"
        case polls = "Poll"
        case quizzes = "Quiz"
        case questions = "Q&A"
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.24))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            header

            let availableTabs = tabs(for: story.overlays)
            if availableTabs.count > 1 {
                tabBar(availableTabs)
            }

            Divider().overlay(Color.white.opacity(0.08))

            Group {
                switch tab {
                case .viewers:
                    viewersList
                case .polls:
                    pollSummary
                case .quizzes:
                    quizSummary
                case .questions:
                    questionsList
                }
            }
        }
        .background(Color.black.opacity(0.94))
        .task { await viewModel.loadIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Viewers")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            if viewModel.total > 0 {
                Text("\(viewModel.total)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            if viewModel.isLoading && viewModel.viewers.isEmpty {
                ProgressView().tint(C.watch)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func tabBar(_ tabs: [SheetTab]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tab == item ? .black : .white.opacity(0.58))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(tab == item ? C.watch : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 12)
    }

    private var viewersList: some View {
        List {
            if let error = viewModel.error, viewModel.viewers.isEmpty {
                Text(error)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(viewModel.viewers) { viewer in
                ViewerRow(viewer: viewer)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .task {
                        if viewer.id == viewModel.viewers.last?.id {
                            await viewModel.loadMore()
                        }
                    }
            }

            if viewModel.isLoading && !viewModel.viewers.isEmpty {
                ProgressView()
                    .tint(C.watch)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var pollSummary: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(pollOverlays(from: story.overlays), id: \.index) { entry in
                    PollResultCard(overlay: entry.overlay, overlayIndex: entry.index, viewers: viewModel.viewers)
                }
            }
            .padding(20)
        }
    }

    private var quizSummary: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(quizOverlays(from: story.overlays), id: \.index) { entry in
                    QuizResultCard(overlay: entry.overlay, overlayIndex: entry.index, viewers: viewModel.viewers)
                }
            }
            .padding(20)
        }
    }

    private var questionsList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(questionReplies(from: viewModel.viewers)) { reply in
                    QuestionReplyRow(reply: reply)
                }
            }
            .padding(20)
        }
    }

    private func tabs(for overlays: [StoryOverlay]) -> [SheetTab] {
        var result: [SheetTab] = [.viewers]
        if overlays.contains(where: { if case .poll = $0 { return true }; return false }) { result.append(.polls) }
        if overlays.contains(where: { if case .quiz = $0 { return true }; return false }) { result.append(.quizzes) }
        if overlays.contains(where: { if case .question = $0 { return true }; return false }) { result.append(.questions) }
        return result
    }

    private struct IndexedOverlay<T> {
        let index: Int
        let overlay: T
    }

    private func pollOverlays(from overlays: [StoryOverlay]) -> [IndexedOverlay<PollOverlayData>] {
        overlays.enumerated().compactMap { index, overlay in
            if case .poll(_, let data) = overlay { return IndexedOverlay(index: index, overlay: data) }
            return nil
        }
    }

    private func quizOverlays(from overlays: [StoryOverlay]) -> [IndexedOverlay<QuizOverlayData>] {
        overlays.enumerated().compactMap { index, overlay in
            if case .quiz(_, let data) = overlay { return IndexedOverlay(index: index, overlay: data) }
            return nil
        }
    }

    private func questionReplies(from viewers: [StoryViewer]) -> [QuestionReplyItem] {
        viewers.flatMap { viewer in
            viewer.responses.compactMap { response in
                guard response.kind == .question, let text = response.text else { return nil }
                return QuestionReplyItem(
                    id: "\(viewer.id)-\(response.overlayIndex)",
                    user: viewer.user,
                    text: text,
                    overlayIndex: response.overlayIndex,
                    viewedAt: viewer.viewedAt
                )
            }
        }
    }
}

struct QuestionReplyItem: Identifiable {
    let id: String
    let user: ViewerUser
    let text: String
    let overlayIndex: Int
    let viewedAt: Date
}

private struct ViewerRow: View {
    let viewer: StoryViewer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ViewerAvatarView(user: viewer.user, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(viewer.user.name ?? "Unknown")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer()
                    Text(viewer.viewedAt.relativeShort())
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.36))
                }

                if !viewer.responses.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(viewer.responses.indices, id: \.self) { index in
                            ResponseBadgeView(response: viewer.responses[index])
                        }
                    }
                }
            }
        }
    }
}

private struct ResponseBadgeView: View {
    let response: ViewerResponse

    var body: some View {
        switch response.kind {
        case .poll:
            badge(icon: "chart.bar.fill", label: response.optionLabel ?? "-", color: C.watch)
        case .quiz:
            badge(
                icon: response.isCorrect == true ? "checkmark" : "xmark",
                label: response.selectedLabel ?? "-",
                color: response.isCorrect == true ? C.watch : .white.opacity(0.7)
            )
        case .question:
            badge(icon: "bubble.left.fill", label: response.text ?? "-", color: C.watch)
        }
    }

    private func badge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .lineLimit(1)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PollResultCard: View {
    let overlay: PollOverlayData
    let overlayIndex: Int
    let viewers: [StoryViewer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overlay.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            let votes = tally()
            let total = votes.values.reduce(0, +)

            ForEach(overlay.options.indices, id: \.self) { index in
                let count = votes[index] ?? 0
                let percent = total > 0 ? Double(count) / Double(total) : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(overlay.options[index])
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text("\(Int((percent * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 4).fill(C.watch.opacity(0.58))
                                .frame(width: geometry.size.width * percent)
                                .animation(.easeOut(duration: 0.25), value: percent)
                        }
                    }
                    .frame(height: 6)
                }
            }

            Text("\(total) vote\(total == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.36))
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tally() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for viewer in viewers {
            for response in viewer.responses where response.kind == .poll && response.overlayIndex == overlayIndex {
                if let optionIndex = response.optionIndex { counts[optionIndex, default: 0] += 1 }
            }
        }
        return counts
    }
}

private struct QuizResultCard: View {
    let overlay: QuizOverlayData
    let overlayIndex: Int
    let viewers: [StoryViewer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overlay.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            let answers = collectAnswers()
            let total = answers.count
            let correctCount = answers.filter { $0.isCorrect == true }.count

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(C.watch)
                Text(total > 0 ? "\(Int(Double(correctCount) / Double(total) * 100))% correct" : "No answers")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                Text(".").foregroundStyle(.white.opacity(0.24))
                Text("\(total) answer\(total == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.46))
            }

            ForEach(overlay.options.indices, id: \.self) { index in
                let count = answers.filter { $0.selectedIndex == index }.count
                let percent = total > 0 ? Double(count) / Double(total) : 0
                let isRight = index == overlay.correctIndex
                HStack(spacing: 8) {
                    Image(systemName: isRight ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isRight ? C.watch : .white.opacity(0.22))
                    Text(overlay.options[index])
                        .font(.system(size: 12))
                        .foregroundStyle(isRight ? C.watch.opacity(0.92) : .white.opacity(0.64))
                    Spacer()
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private struct AnswerResult {
        let selectedIndex: Int?
        let isCorrect: Bool?
    }

    private func collectAnswers() -> [AnswerResult] {
        viewers.flatMap { viewer in
            viewer.responses
                .filter { $0.kind == .quiz && $0.overlayIndex == overlayIndex }
                .map { AnswerResult(selectedIndex: $0.selectedIndex, isCorrect: $0.isCorrect) }
        }
    }
}

private struct QuestionReplyRow: View {
    let reply: QuestionReplyItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ViewerAvatarView(user: reply.user, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(reply.user.name ?? "Unknown")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    Text(reply.viewedAt.relativeShort())
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.34))
                }
                Text(reply.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) { content }
    }
}
