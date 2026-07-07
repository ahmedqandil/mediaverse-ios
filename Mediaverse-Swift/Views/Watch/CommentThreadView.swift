import SwiftUI

// MARK: - Shared web-parity comment thread

enum CommentThreadTarget: Equatable {
    case video(String)
    case episode(String)
    case collection(String)

    var id: String {
        switch self {
        case .video(let id), .episode(let id), .collection(let id): return id
        }
    }
}

enum CommentInputPosition {
    case top
    case bottom
}

struct CommentThreadView: View {
    let target: CommentThreadTarget
    var initialComments: [Comment]? = nil
    var inputPosition: CommentInputPosition = .top
    var showsHeader: Bool = true
    var previewLimit: Int? = nil
    var onShowMore: ((Int) -> Void)? = nil
    var onCountChange: ((Int) -> Void)? = nil

    @State private var comments: [Comment]
    @State private var isLoading: Bool
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var likedCommentIds = Set<String>()
    @State private var flaggedCommentIds = Set<String>()
    @State private var loadError: String? = nil
    @State private var replyTarget: Comment? = nil

    @EnvironmentObject private var auth: AuthManager

    private var contentAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.88)
    }

    init(
        target: CommentThreadTarget,
        initialComments: [Comment]? = nil,
        inputPosition: CommentInputPosition = .top,
        showsHeader: Bool = true,
        previewLimit: Int? = nil,
        onShowMore: ((Int) -> Void)? = nil,
        onCountChange: ((Int) -> Void)? = nil
    ) {
        self.target = target
        self.initialComments = initialComments
        self.inputPosition = inputPosition
        self.showsHeader = showsHeader
        self.previewLimit = previewLimit
        self.onShowMore = onShowMore
        self.onCountChange = onCountChange
        _comments = State(initialValue: initialComments ?? [])
        _isLoading = State(initialValue: initialComments == nil)
    }

    var body: some View {
        Group {
            if inputPosition == .bottom {
                VStack(spacing: 0) {
                    ScrollView {
                        threadContent
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    Divider().background(C.borderSubtle)
                    composer
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(C.bg)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if showsHeader {
                        Text("Comments\(commentCount > 0 ? " (\(commentCount))" : "")")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(C.text)
                    }
                    composer
                    threadContent
                }
            }
        }
        .task { await loadIfNeeded() }
        .onChange(of: target.id) { _, _ in
            Task { await reload() }
        }
        .animation(contentAnimation, value: isLoading)
        .animation(contentAnimation, value: commentIdentity)
    }

    private var commentCount: Int {
        comments.reduce(0) { total, comment in
            total + 1 + (comment.replies?.count ?? comment.replyCount ?? 0)
        }
    }

    private var composer: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(user: nil, size: 32)

            VStack(alignment: .trailing, spacing: 8) {
                if let replyTarget {
                    HStack(spacing: 6) {
                        Text("Replying to \(replyTarget.user?.name ?? "comment")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(C.textMuted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            self.replyTarget = nil
                            commentText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(C.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField(composerPlaceholder, text: $commentText, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundStyle(C.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, inputPosition == .bottom ? 9 : 10)
                    .background(inputPosition == .bottom ? Color.white.opacity(0.07) : C.surface)
                    .clipShape(RoundedRectangle(cornerRadius: inputPosition == .bottom ? 18 : 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: inputPosition == .bottom ? 18 : 8)
                            .stroke(C.border, lineWidth: 1)
                    }
                    .lineLimit(1...4)
                    .disabled(!auth.isAuthenticated || isSubmitting)
                    .onTapGesture {
                        // Native auth flow is tab/profile driven today; keep the web parity disabled state visible.
                    }

                if !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            commentText = ""
                            replyTarget = nil
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(C.textMuted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(C.elevated)
                                .clipShape(Capsule())
                        }

                        Button {
                            Task { await submitComment() }
                        } label: {
                            if isSubmitting {
                                ProgressView().tint(.black)
                                    .frame(width: 34, height: 34)
                                    .background(C.watch)
                                    .clipShape(Circle())
                            } else {
                                Text("Comment")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(C.bg)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(C.watch)
                                    .clipShape(Capsule())
                            }
                        }
                        .disabled(isSubmitting)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var composerPlaceholder: String {
        if !auth.isAuthenticated { return "Sign in to comment" }
        if let replyTarget { return "Reply to \(replyTarget.user?.name ?? "comment")…" }
        return "Add a comment…"
    }

    @ViewBuilder
    private var threadContent: some View {
        if isLoading {
            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 10) {
                        Circle().fill(C.elevated).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).fill(C.elevated).frame(width: 90, height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(C.elevated).frame(height: 10)
                        }
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else if loadError != nil {
            Text("Could not load comments.")
                .font(.system(size: 13))
                .foregroundStyle(C.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
                .transition(.opacity)
        } else if comments.isEmpty {
            Text("No comments yet. Be the first.")
                .font(.system(size: 13))
                .foregroundStyle(C.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, inputPosition == .bottom ? 24 : 18)
                .transition(.opacity)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(visibleComments) { comment in
                    SharedCommentRow(
                        comment: comment,
                        depth: 0,
                        usesExternalReplyComposer: inputPosition == .bottom,
                        likedCommentIds: $likedCommentIds,
                        flaggedCommentIds: $flaggedCommentIds,
                        onBeginReply: { replyTarget = $0 },
                        onLike: toggleLike,
                        onFlag: flagComment,
                        onReply: submitReply
                    )
                }
                if let previewLimit, commentCount > previewLimit {
                    showMoreButton(
                        title: "Show \(commentCount - previewLimit) more comment\(commentCount - previewLimit == 1 ? "" : "s")",
                        count: commentCount
                    )
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }

    private var visibleComments: [Comment] {
        if let previewLimit {
            return Array(comments.prefix(previewLimit))
        }
        return comments
    }

    private var commentIdentity: String {
        visibleComments.map(\.id).joined(separator: "|") + ":\(commentCount)"
    }

    private func showMoreButton(title: String, count: Int) -> some View {
        Button {
            onShowMore?(count)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(C.watch)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(C.watch)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func avatar(user: CommentUser?, size: CGFloat) -> some View {
        if let url = C.mediaURL(user?.image) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(C.elevated)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(C.elevated)
                .frame(width: size, height: size)
                .overlay {
                    Text(String((user?.name ?? "?").prefix(1)).uppercased())
                        .font(.system(size: max(9, size * 0.34), weight: .bold))
                        .foregroundStyle(C.textMuted)
                }
        }
    }

    private func loadIfNeeded() async {
        guard initialComments == nil else {
            onCountChange?(commentCount)
            return
        }
        await reload()
    }

    @MainActor
    private func reload() async {
        withAnimation(.easeOut(duration: 0.16)) {
            isLoading = true
            loadError = nil
        }
        do {
            let fetchedComments = try await fetchTargetComments()
            withAnimation(contentAnimation) {
                comments = fetchedComments
                isLoading = false
            }
            onCountChange?(commentCount)
        } catch {
            withAnimation(contentAnimation) {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func fetchTargetComments() async throws -> [Comment] {
        switch target {
        case .video(let id):
            return try await APIClient.shared.fetchComments(videoId: id)
        case .episode(let id):
            return try await APIClient.shared.fetchComments(episodeId: id)
        case .collection(let id):
            return try await APIClient.shared.fetchComments(collectionId: id)
        }
    }

    private func submitComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard auth.isAuthenticated, !text.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        do {
            if let replyTarget {
                let reply = try await postTargetComment(content: text, parentId: replyTarget.id)
                withAnimation(contentAnimation) {
                    comments = comments.map { $0.addingReply(reply.withRepliesIfNeeded(), to: replyTarget.id) }
                    self.replyTarget = nil
                }
            } else {
                let comment = try await postTargetComment(content: text, parentId: nil)
                withAnimation(contentAnimation) {
                    comments.insert(comment.withRepliesIfNeeded(), at: 0)
                }
            }
            commentText = ""
            onCountChange?(commentCount)
        } catch {}
        isSubmitting = false
    }

    private func submitReply(parentId: String, text: String) async {
        guard auth.isAuthenticated else { return }
        do {
            let reply = try await postTargetComment(content: text, parentId: parentId)
            withAnimation(contentAnimation) {
                comments = comments.map { $0.addingReply(reply.withRepliesIfNeeded(), to: parentId) }
            }
            onCountChange?(commentCount)
        } catch {}
    }

    private func postTargetComment(content: String, parentId: String?) async throws -> Comment {
        switch target {
        case .video(let id):
            return try await APIClient.shared.postComment(content: content, videoId: id, parentId: parentId)
        case .episode(let id):
            return try await APIClient.shared.postComment(content: content, episodeId: id, parentId: parentId)
        case .collection(let id):
            return try await APIClient.shared.postComment(content: content, collectionId: id, parentId: parentId)
        }
    }

    private func toggleLike(commentId: String, currentLikes: Int) {
        guard auth.isAuthenticated else { return }
        let wasLiked = likedCommentIds.contains(commentId)
        withAnimation(.easeInOut(duration: 0.16)) {
            if wasLiked { likedCommentIds.remove(commentId) } else { likedCommentIds.insert(commentId) }
            comments = comments.map { $0.updatingLikes(commentId: commentId, likes: max(0, currentLikes + (wasLiked ? -1 : 1))) }
        }
        Task {
            _ = try? await APIClient.shared.likeComment(commentId: commentId, liked: !wasLiked)
        }
    }

    private func flagComment(commentId: String) {
        guard auth.isAuthenticated, !flaggedCommentIds.contains(commentId) else { return }
        flaggedCommentIds.insert(commentId)
        Task {
            _ = try? await APIClient.shared.flagComment(commentId: commentId)
        }
    }
}

private struct SharedCommentRow: View {
    let comment: Comment
    let depth: Int
    let usesExternalReplyComposer: Bool
    @Binding var likedCommentIds: Set<String>
    @Binding var flaggedCommentIds: Set<String>
    let onBeginReply: (Comment) -> Void
    let onLike: (String, Int) -> Void
    let onFlag: (String) -> Void
    let onReply: (String, String) async -> Void

    @State private var isReplyOpen = false
    @State private var replyText = ""
    @State private var isSendingReply = false
    @State private var repliesExpanded = true

    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(comment.user?.name ?? "Anonymous")
                        .font(.system(size: depth == 0 ? 12 : 11, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(commentTimeAgo(comment.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(C.textMuted.opacity(0.65))
                }

                if comment.isRemoved == true {
                    Text("[Comment removed]")
                        .font(.system(size: depth == 0 ? 13 : 12))
                        .foregroundStyle(C.textMuted.opacity(0.55))
                        .italic()
                } else {
                    Text(comment.content ?? "")
                        .font(.system(size: depth == 0 ? 13 : 12))
                        .foregroundStyle(C.text.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if comment.isRemoved != true {
                    actionRow
                }

                if isReplyOpen {
                    replyComposer
                }

                if repliesExpanded, let replies = comment.replies, !replies.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(replies) { reply in
                            SharedCommentRow(
                                comment: reply,
                                depth: depth + 1,
                                usesExternalReplyComposer: usesExternalReplyComposer,
                                likedCommentIds: $likedCommentIds,
                                flaggedCommentIds: $flaggedCommentIds,
                                onBeginReply: onBeginReply,
                                onLike: onLike,
                                onFlag: onFlag,
                                onReply: onReply
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, depth > 0 ? 16 : 0)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle()
                    .fill(C.borderSubtle)
                    .frame(width: 1)
                    .padding(.leading, 3)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button {
                onLike(comment.id, comment.likes ?? 0)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: likedCommentIds.contains(comment.id) ? "heart.fill" : "heart")
                        .font(.system(size: 11))
                    if (comment.likes ?? 0) > 0 {
                        Text("\(comment.likes ?? 0)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(likedCommentIds.contains(comment.id) ? C.watch : C.textMuted.opacity(0.75))
            }
            .buttonStyle(.plain)

            if auth.isAuthenticated, depth < 2 {
                Button {
                    if usesExternalReplyComposer {
                        onBeginReply(comment)
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { isReplyOpen.toggle() }
                    }
                } label: {
                    Text("Reply")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.textMuted.opacity(0.75))
                }
                .buttonStyle(.plain)
            }

            if depth == 0, visibleReplyCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { repliesExpanded.toggle() }
                } label: {
                    Text(repliesExpanded ? "Hide" : "\(visibleReplyCount) repl\(visibleReplyCount == 1 ? "y" : "ies")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.watch.opacity(0.85))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            if auth.isAuthenticated {
                if flaggedCommentIds.contains(comment.id) {
                    Text("Reported")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.6))
                } else {
                    Button {
                        onFlag(comment.id)
                    } label: {
                        Image(systemName: "flag")
                            .font(.system(size: 10))
                            .foregroundStyle(C.textMuted.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }

    private var replyComposer: some View {
        HStack(spacing: 8) {
            TextField("Write a reply…", text: $replyText, axis: .vertical)
                .font(.system(size: 12))
                .foregroundStyle(C.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .lineLimit(1...3)

            Button {
                Task { await sendReply() }
            } label: {
                if isSendingReply {
                    ProgressView().tint(.black)
                        .frame(width: 30, height: 30)
                        .background(C.watch)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(C.bg)
                        .frame(width: 30, height: 30)
                        .background(C.watch)
                        .clipShape(Circle())
                }
            }
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingReply)
        }
        .padding(.top, 6)
    }

    private var visibleReplyCount: Int {
        comment.replies?.count ?? comment.replyCount ?? 0
    }

    private var avatar: some View {
        Group {
            if let url = C.mediaURL(comment.user?.image) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(C.elevated)
                }
            } else {
                Circle()
                    .fill(C.elevated)
                    .overlay {
                        Text(String((comment.user?.name ?? "?").prefix(1)).uppercased())
                            .font(.system(size: depth == 0 ? 11 : 9, weight: .bold))
                            .foregroundStyle(C.textMuted)
                    }
            }
        }
        .frame(width: depth == 0 ? 32 : 26, height: depth == 0 ? 32 : 26)
        .clipShape(Circle())
    }

    private func sendReply() async {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingReply else { return }
        isSendingReply = true
        await onReply(comment.id, text)
        replyText = ""
        isReplyOpen = false
        isSendingReply = false
    }
}

private extension Comment {
    func withRepliesIfNeeded() -> Comment {
        Comment(
            id: id,
            content: content,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            replies: replies ?? [],
            replyCount: replyCount
        )
    }

    func updatingLikes(commentId: String, likes: Int) -> Comment {
        Comment(
            id: id,
            content: content,
            isRemoved: isRemoved,
            likes: id == commentId ? likes : self.likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            replies: replies?.map { $0.updatingLikes(commentId: commentId, likes: likes) },
            replyCount: replyCount
        )
    }

    func addingReply(_ reply: Comment, to parentId: String) -> Comment {
        if id == parentId {
            return Comment(
                id: id,
                content: content,
                isRemoved: isRemoved,
                likes: likes,
                createdAt: createdAt,
                parentId: self.parentId,
                user: user,
                replies: (replies ?? []) + [reply],
                replyCount: (replyCount ?? replies?.count ?? 0) + 1
            )
        }
        return Comment(
            id: id,
            content: content,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: self.parentId,
            user: user,
            replies: replies?.map { $0.addingReply(reply, to: parentId) },
            replyCount: replyCount
        )
    }
}

private func commentTimeAgo(_ iso: String) -> String {
    guard let date = parseCommentDate(iso) else { return "" }
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(max(seconds, 0))s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86400)d ago"
}

private func parseCommentDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = standard.date(from: value) { return date }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    ] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}
