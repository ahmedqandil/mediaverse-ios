import SwiftUI

// MARK: - Shared web-parity comment thread

enum CommentThreadTarget: Equatable {
    case video(String)
    case episode(String)
    case collection(String)
    case post(String)
    case ripple(String)
    case ripplePhoto(String)

    var id: String {
        switch self {
        case .video(let id), .episode(let id), .collection(let id), .post(let id),
             .ripple(let id), .ripplePhoto(let id):
            return id
        }
    }
}

enum CommentInputPosition {
    case top
    case bottom
}

struct StandardCommentsSheet: View {
    let target: CommentThreadTarget
    var title: String = "Comments"
    var initialComments: [Comment]? = nil
    var initialCount: Int? = nil
    var autoFocusComposer: Bool = false
    var onClose: (() -> Void)? = nil
    var onCountChange: ((Int) -> Void)? = nil

    @State private var displayedCount: Int?

    init(
        target: CommentThreadTarget,
        title: String = "Comments",
        initialComments: [Comment]? = nil,
        initialCount: Int? = nil,
        autoFocusComposer: Bool = false,
        onClose: (() -> Void)? = nil,
        onCountChange: ((Int) -> Void)? = nil
    ) {
        self.target = target
        self.title = title
        self.initialComments = initialComments
        self.initialCount = initialCount
        self.autoFocusComposer = autoFocusComposer
        self.onClose = onClose
        self.onCountChange = onCountChange
        _displayedCount = State(initialValue: initialCount ?? initialComments?.totalCommentCount)
    }

    var body: some View {
        NavigationStack {
            CommentThreadView(
                target: target,
                initialComments: seedComments,
                inputPosition: .bottom,
                showsHeader: false,
                autoFocusComposer: autoFocusComposer,
                onCountChange: { count in
                    displayedCount = count
                    onCountChange?(count)
                }
            )
            .navigationTitle(titleWithCount)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(C.text)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close comments")
                    }
                }
            }
        }
        .background(C.bg)
        .presentationDetents([.fraction(0.76), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(C.bg)
        .onAppear {
            NotificationCenter.default.post(name: .commentsOverlayVisibilityChanged, object: true)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .commentsOverlayVisibilityChanged, object: false)
        }
    }

    private var titleWithCount: String {
        guard let displayedCount, displayedCount > 0 else { return title }
        return "\(title) (\(displayedCount))"
    }

    private var seedComments: [Comment]? {
        guard let initialComments, !initialComments.isEmpty else { return nil }
        return initialComments
    }
}

struct CommentThreadView: View {
    let target: CommentThreadTarget
    var initialComments: [Comment]? = nil
    var inputPosition: CommentInputPosition = .top
    var showsHeader: Bool = true
    var previewLimit: Int? = nil
    var autoFocusComposer: Bool = false
    var onShowMore: ((Int) -> Void)? = nil
    var onCountChange: ((Int) -> Void)? = nil

    @State private var comments: [Comment]
    @State private var isLoading: Bool
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var likedCommentIds = Set<String>()
    @State private var flaggedCommentIds = Set<String>()
    @State private var loadError: String? = nil
    @State private var submitError: String? = nil
    @State private var replyTarget: Comment? = nil
    @FocusState private var isComposerFocused: Bool

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
        autoFocusComposer: Bool = false,
        onShowMore: ((Int) -> Void)? = nil,
        onCountChange: ((Int) -> Void)? = nil
    ) {
        self.target = target
        self.initialComments = initialComments
        self.inputPosition = inputPosition
        self.showsHeader = showsHeader
        self.previewLimit = previewLimit
        self.autoFocusComposer = autoFocusComposer
        self.onShowMore = onShowMore
        self.onCountChange = onCountChange
        _comments = State(initialValue: initialComments ?? [])
        _isLoading = State(initialValue: initialComments == nil)
    }

    var body: some View {
        Group {
            if inputPosition == .bottom {
                ScrollView {
                    threadContent
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .padding(.bottom, stickyComposerReserve)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider().background(C.borderSubtle)
                        composer
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(C.bg)
                    }
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
        .task(id: target.id) {
            if autoFocusComposer {
                Task { await focusComposerAfterSheetPresentation() }
            }
            await loadIfNeeded()
        }
        .animation(contentAnimation, value: isLoading)
        .animation(contentAnimation, value: commentIdentity)
    }

    private var stickyComposerReserve: CGFloat {
        76
    }

    private var supportsCommentManagement: Bool {
        if case .post = target { return false }
        return true
    }

    private var supportsCommentFlags: Bool {
        if case .post = target { return false }
        if case .ripple = target { return false }
        if case .ripplePhoto = target { return false }
        return true
    }

    private var commentCount: Int {
        displayComments.reduce(0) { total, comment in
            total + 1 + (comment.replies?.count ?? 0)
        }
    }

    private var displayComments: [Comment] {
        comments.compactMap { $0.removingSoftDeleted() }
    }

    private var composer: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(image: auth.currentUser?.image, name: auth.currentUser?.name, size: 32)

            VStack(alignment: .trailing, spacing: 8) {
                if let replyTarget {
                    HStack(spacing: 6) {
                        Text("Replying to \(replyTarget.displayName)")
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

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(composerPlaceholder, text: $commentText, axis: .vertical)
                        .font(.system(size: 13))
                        .foregroundStyle(C.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, inputPosition == .bottom ? 9 : 10)
                        .background(inputPosition == .bottom ? C.elevated : C.surface)
                        .clipShape(RoundedRectangle(cornerRadius: inputPosition == .bottom ? 18 : 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: inputPosition == .bottom ? 18 : 8)
                                .stroke(C.border, lineWidth: 1)
                        }
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .focused($isComposerFocused)
                        .disabled(!auth.isAuthenticated || isSubmitting)
                        .onSubmit {
                            Task { await submitComment() }
                        }
                        .onTapGesture {
                            if auth.isAuthenticated {
                                isComposerFocused = true
                            }
                        }

                    Button {
                        Task { await submitComment() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(canSubmitComment ? C.watch : C.elevated)
                                .frame(width: 38, height: 38)
                            if isSubmitting {
                                ProgressView()
                                    .tint(canSubmitComment ? C.bg : C.textMuted)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(canSubmitComment ? C.bg : C.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmitComment)
                    .accessibilityLabel("Comment")
                }

                MentionAutocompletePanel(text: $commentText)
                    .zIndex(1)

                if let submitError {
                    Text(submitError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var composerPlaceholder: String {
        if !auth.isAuthenticated { return "Sign in to comment" }
        if let replyTarget { return "Reply to \(replyTarget.displayName)…" }
        return "Add a comment…"
    }

    private var canSubmitComment: Bool {
        auth.isAuthenticated &&
        !isSubmitting &&
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        } else if displayComments.isEmpty {
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
                        allowsManagement: supportsCommentManagement,
                        allowsFlagging: supportsCommentFlags,
                        likedCommentIds: $likedCommentIds,
                        flaggedCommentIds: $flaggedCommentIds,
                        onBeginReply: { replyTarget = $0 },
                        onLike: toggleLike,
                        onFlag: flagComment,
                        onReply: submitReply,
                        onEdit: editComment,
                        onDelete: deleteComment
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
            return Array(displayComments.prefix(previewLimit))
        }
        return displayComments
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
    private func avatar(image: String?, name: String?, size: CGFloat) -> some View {
        if let url = C.mediaURL(image) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: size, height: size)
            ) { image in
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
                    Text(String((name ?? "?").prefix(1)).uppercased())
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
    private func focusComposerAfterSheetPresentation() async {
        guard auth.isAuthenticated else { return }
        try? await Task.sleep(nanoseconds: inputPosition == .bottom ? 120_000_000 : 220_000_000)
        guard auth.isAuthenticated else { return }
        isComposerFocused = true
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
                comments = fetchedComments.compactMap { $0.removingSoftDeleted() }
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
        case .post(let id):
            let postComments = try await APIClient.shared.fetchPostComments(postId: id)
            return postComments.map { $0.asSharedComment }
        case .ripple(let id):
            let comments = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).rippleComments(postId: id)
            return comments.map(\.asSharedComment)
        case .ripplePhoto(let id):
            let comments = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).ripplePhotoComments(attachmentId: id)
            return comments.map(\.asSharedComment)
        }
    }

    private func submitComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard auth.isAuthenticated, !text.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
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
            isComposerFocused = false
            onCountChange?(commentCount)
        } catch {
            submitError = error.localizedDescription
            isComposerFocused = true
        }
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

    private func editComment(commentId: String, text: String) async throws {
        guard auth.isAuthenticated else { return }
        let updatedContent: String?
        let updatedHTML: String?
        switch target {
        case .ripple:
            let updated = try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .editRippleComment(commentId: commentId, content: text)
            updatedContent = updated.content
            updatedHTML = updated.contentHTML
        case .ripplePhoto:
            let updated = try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .editRipplePhotoComment(commentId: commentId, content: text)
            updatedContent = updated.content
            updatedHTML = updated.contentHTML
        default:
            let updated = try await APIClient.shared.editComment(commentId: commentId, content: text)
            updatedContent = updated.content
            updatedHTML = updated.contentHtml
        }
        withAnimation(contentAnimation) {
            comments = comments.map {
                $0.updatingContent(
                    commentId: commentId,
                    content: updatedContent ?? text,
                    contentHtml: updatedHTML
                )
            }
        }
    }

    private func deleteComment(commentId: String) async throws {
        guard auth.isAuthenticated else { return }
        switch target {
        case .ripple:
            try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .deleteRippleComment(commentId: commentId)
        case .ripplePhoto:
            try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .deleteRipplePhotoComment(commentId: commentId)
        default:
            try await APIClient.shared.deleteComment(commentId: commentId)
        }
        withAnimation(contentAnimation) {
            comments = comments.compactMap { $0.removing(commentId: commentId) }
            if replyTarget?.id == commentId {
                replyTarget = nil
                commentText = ""
            }
        }
        onCountChange?(commentCount)
    }

    private func postTargetComment(content: String, parentId: String?) async throws -> Comment {
        switch target {
        case .video(let id):
            return try await APIClient.shared.postComment(content: content, videoId: id, parentId: parentId)
        case .episode(let id):
            return try await APIClient.shared.postComment(content: content, episodeId: id, parentId: parentId)
        case .collection(let id):
            return try await APIClient.shared.postComment(content: content, collectionId: id, parentId: parentId)
        case .post(let id):
            let comment = try await APIClient.shared.createPostComment(postId: id, content: content, parentId: parentId)
            return comment.asSharedComment
        case .ripple(let id):
            let comment = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).createRippleComment(postId: id, content: content, parentId: parentId)
            return comment.asSharedComment
        case .ripplePhoto(let id):
            let comment = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).createRipplePhotoComment(attachmentId: id, content: content, parentId: parentId)
            return comment.asSharedComment
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
            if case .post(let postId) = target {
                _ = try? await APIClient.shared.likePostComment(postId: postId, commentId: commentId, liked: !wasLiked)
            } else if case .ripple = target {
                _ = try? await LegacySocialAPIAdapter(
                    transport: APIClient.shared
                ).toggleRippleCommentLike(commentId: commentId)
            } else if case .ripplePhoto = target {
                _ = try? await LegacySocialAPIAdapter(
                    transport: APIClient.shared
                ).toggleRipplePhotoCommentLike(commentId: commentId)
            } else {
                _ = try? await APIClient.shared.likeComment(commentId: commentId, liked: !wasLiked)
            }
        }
    }

    private func flagComment(commentId: String) {
        guard supportsCommentFlags, auth.isAuthenticated, !flaggedCommentIds.contains(commentId) else { return }
        flaggedCommentIds.insert(commentId)
        Task {
            _ = try? await APIClient.shared.flagComment(commentId: commentId)
        }
    }
}

extension Array where Element == Comment {
    var totalCommentCount: Int {
        reduce(0) { total, comment in
            total + 1 + (comment.replies?.totalCommentCount ?? comment.replyCount ?? 0)
        }
    }
}

private struct SharedCommentRow: View {
    let comment: Comment
    let depth: Int
    let usesExternalReplyComposer: Bool
    let allowsManagement: Bool
    let allowsFlagging: Bool
    @Binding var likedCommentIds: Set<String>
    @Binding var flaggedCommentIds: Set<String>
    let onBeginReply: (Comment) -> Void
    let onLike: (String, Int) -> Void
    let onFlag: (String) -> Void
    let onReply: (String, String) async -> Void
    let onEdit: (String, String) async throws -> Void
    let onDelete: (String) async throws -> Void

    @State private var isReplyOpen = false
    @State private var replyText = ""
    @State private var isSendingReply = false
    @State private var repliesExpanded = true
    @State private var isEditing = false
    @State private var editText = ""
    @State private var isSavingEdit = false
    @State private var isDeleting = false
    @State private var editError: String? = nil

    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(comment.displayName)
                        .font(.system(size: depth == 0 ? 12 : 11, weight: .semibold))
                        .foregroundStyle(C.text)
                    Text(commentTimeAgo(comment.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(C.textMuted.opacity(0.65))
                }

                if comment.isSoftDeletedForDisplay {
                    EmptyView()
                } else if isEditing {
                    editComposer
                } else {
                    MentionText(
                        plain: comment.content,
                        html: comment.contentHtml,
                        font: .system(size: depth == 0 ? 13 : 12),
                        color: C.text.opacity(0.82)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !comment.isSoftDeletedForDisplay, !isEditing {
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
                                allowsManagement: allowsManagement,
                                allowsFlagging: allowsFlagging,
                                likedCommentIds: $likedCommentIds,
                                flaggedCommentIds: $flaggedCommentIds,
                                onBeginReply: onBeginReply,
                                onLike: onLike,
                                onFlag: onFlag,
                                onReply: onReply,
                                onEdit: onEdit,
                                onDelete: onDelete
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

            if allowsManagement, isOwnComment {
                Button {
                    editText = comment.content ?? ""
                    editError = nil
                    withAnimation(.easeInOut(duration: 0.18)) { isEditing = true }
                } label: {
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.textMuted.opacity(0.75))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await deleteCurrentComment() }
                } label: {
                    Text(isDeleting ? "Deleting" : "Delete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.78))
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
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

            if allowsFlagging, auth.isAuthenticated {
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

    private var editComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Edit comment", text: $editText, axis: .vertical)
                .font(.system(size: depth == 0 ? 13 : 12))
                .foregroundStyle(C.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                .lineLimit(1...4)
                .disabled(isSavingEdit)

            MentionAutocompletePanel(text: $editText)

            if let editError {
                Text(editError)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red.opacity(0.8))
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    editText = ""
                    editError = nil
                    withAnimation(.easeInOut(duration: 0.18)) { isEditing = false }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textMuted)
                .disabled(isSavingEdit)

                Button {
                    Task { await saveEdit() }
                } label: {
                    Text(isSavingEdit ? "Saving..." : "Save")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(C.watch)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingEdit || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            MentionAutocompletePanel(text: $replyText)
        }
        .padding(.top, 6)
    }

    private var visibleReplyCount: Int {
        comment.replies?.count ?? comment.replyCount ?? 0
    }

    private var isOwnComment: Bool {
        auth.currentUser?.id == comment.user?.id
    }

    private var avatar: some View {
        Group {
            if let url = C.mediaURL(comment.avatarImage) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: depth == 0 ? 34 : 28, height: depth == 0 ? 34 : 28)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(C.elevated)
                }
            } else {
                Circle()
                    .fill(C.elevated)
                    .overlay {
                        Text(comment.initials)
                            .font(.system(size: depth == 0 ? 11 : 9, weight: .bold))
                            .foregroundStyle(C.textMuted)
                    }
            }
        }
        .frame(width: depth == 0 ? 32 : 26, height: depth == 0 ? 32 : 26)
        .clipShape(Circle())
    }

    private func saveEdit() async {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSavingEdit else { return }
        isSavingEdit = true
        editError = nil
        do {
            try await onEdit(comment.id, text)
            editText = ""
            withAnimation(.easeInOut(duration: 0.18)) { isEditing = false }
        } catch {
            editError = "Could not save edit."
        }
        isSavingEdit = false
    }

    private func deleteCurrentComment() async {
        guard !isDeleting else { return }
        isDeleting = true
        do {
            try await onDelete(comment.id)
        } catch {
            editError = "Could not delete comment."
            isDeleting = false
        }
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
    var displayName: String {
        actorShow?.title ?? actorChannel?.name ?? user?.name ?? "Anonymous"
    }

    var avatarImage: String? {
        actorShow?.coverUrl ?? actorChannel?.avatarUrl ?? user?.image
    }

    var initials: String {
        String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?").uppercased()
    }

    func withRepliesIfNeeded() -> Comment {
        Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: replies ?? [],
            replyCount: replyCount
        )
    }

    var isSoftDeletedForDisplay: Bool {
        if isRemoved == true { return true }
        if deletedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if removedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedContent, !trimmedContent.isEmpty else { return true }
        let normalized = trimmedContent
            .trimmingCharacters(in: CharacterSet(charactersIn: "[](){}"))
            .lowercased()
        return normalized == "removed"
            || normalized == "deleted"
            || normalized == "comment removed"
            || normalized == "comment deleted"
            || normalized == "this comment was removed"
            || normalized == "this comment was deleted"
            || normalized == "this comment has been removed"
            || normalized == "this comment has been deleted"
    }

    func removingSoftDeleted() -> Comment? {
        guard !isSoftDeletedForDisplay else { return nil }
        let visibleReplies = replies?.compactMap { $0.removingSoftDeleted() }
        return Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: visibleReplies,
            replyCount: visibleReplies?.count ?? replyCount
        )
    }

    func updatingLikes(commentId: String, likes: Int) -> Comment {
        Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: isRemoved,
            likes: id == commentId ? likes : self.likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: replies?.map { $0.updatingLikes(commentId: commentId, likes: likes) },
            replyCount: replyCount
        )
    }

    func updatingContent(commentId: String, content: String?, contentHtml: String?) -> Comment {
        Comment(
            id: id,
            content: id == commentId ? content : self.content,
            contentHtml: id == commentId ? contentHtml : self.contentHtml,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: replies?.map { $0.updatingContent(commentId: commentId, content: content, contentHtml: contentHtml) },
            replyCount: replyCount
        )
    }

    func removing(commentId: String) -> Comment? {
        guard id != commentId else { return nil }
        let remainingReplies = replies?.compactMap { $0.removing(commentId: commentId) }
        return Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: remainingReplies,
            replyCount: remainingReplies?.count ?? replyCount
        )
    }

    func addingReply(_ reply: Comment, to parentId: String) -> Comment {
        if id == parentId {
            return Comment(
                id: id,
                content: content,
                contentHtml: contentHtml,
                isRemoved: isRemoved,
                likes: likes,
                createdAt: createdAt,
                parentId: self.parentId,
                user: user,
                actorChannel: actorChannel,
                actorShow: actorShow,
                replies: (replies ?? []) + [reply],
                replyCount: (replyCount ?? replies?.count ?? 0) + 1
            )
        }
        return Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: isRemoved,
            likes: likes,
            createdAt: createdAt,
            parentId: self.parentId,
            user: user,
            actorChannel: actorChannel,
            actorShow: actorShow,
            replies: replies?.map { $0.addingReply(reply, to: parentId) },
            replyCount: replyCount
        )
    }
}

private extension PostComment {
    var asSharedComment: Comment {
        Comment(
            id: id,
            content: content,
            contentHtml: contentHtml,
            isRemoved: false,
            likes: likes,
            createdAt: createdAt,
            parentId: parentId,
            user: user.map { CommentUser(id: $0.id, name: $0.name, image: $0.image) },
            actorChannel: nil,
            actorShow: nil,
            replies: replies?.map(\.asSharedComment),
            replyCount: replies?.count
        )
    }
}

private extension RippleComment {
    var asSharedComment: Comment {
        Comment(
            id: id,
            content: content,
            contentHtml: contentHTML,
            isRemoved: false,
            likes: likeCount,
            createdAt: createdAt,
            parentId: parentId,
            user: CommentUser(id: user.id, name: user.name ?? user.handle, image: user.image),
            actorChannel: nil,
            actorShow: nil,
            replies: replies.map(\.asSharedComment),
            replyCount: replies.count
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
