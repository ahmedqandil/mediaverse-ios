import SwiftUI
import AVFoundation
import UIKit

// MARK: - PostSectionView
// Mirrors PostSection.tsx exactly:
//   collapsible "N Clip reactions" header → list of FullWidthPostCards
//   each card: thumbnail(148pt,16:9) + content(user, caption, like/comment/share/delete)
//   inline comments expandable per card with reply support

// MARK: - Target (video or episode)

enum PostSectionTarget {
    case video(String)
    case episode(String)
    var apiBase: String {
        switch self {
        case .video(let id):   return "/api/videos/\(id)/posts"
        case .episode(let id): return "/api/episodes/\(id)/posts"
        }
    }
}

// MARK: - Helpers

private func timeAgo(_ isoString: String) -> String {
    guard let date = parsePostDate(isoString) else { return "" }
    let s = Int(-date.timeIntervalSinceNow)
    if s < 5 { return "just now" }
    if s < 60   { return "\(max(s, 0))s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

private func parsePostDate(_ value: String) -> Date? {
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

private func fmtSec(_ s: Int) -> String {
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

// MARK: - Post comment row (single comment + replies)

private struct PostCommentRow: View {
    let postId: String
    let comment: PostComment
    let depth: Int
    let onReplyAdded: (String, PostComment) -> Void

    @State private var likes: Int
    @State private var liked = false
    @State private var replyOpen = false
    @State private var replyText = ""
    @State private var sending = false

    @EnvironmentObject private var auth: AuthManager

    init(postId: String, comment: PostComment, depth: Int = 0, onReplyAdded: @escaping (String, PostComment) -> Void) {
        self.postId = postId
        self.comment = comment
        self.depth = depth
        self.onReplyAdded = onReplyAdded
        _likes = State(initialValue: comment.likes)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Avatar
            Circle()
                .fill(C.elevated)
                .frame(width: depth > 0 ? 14 : 18, height: depth > 0 ? 14 : 18)
                .overlay {
                    if let url = C.mediaURL(comment.user?.image) {
                        AsyncImage(url: url) { i in i.resizable().scaledToFill() } placeholder: { EmptyView() }
                            .clipShape(Circle())
                    } else {
                        Text(String((comment.user?.name ?? "?").prefix(1)).uppercased())
                            .font(.system(size: depth > 0 ? 7 : 8, weight: .bold))
                            .foregroundStyle(C.watch)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(comment.user?.name ?? "User")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text(comment.content)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text(timeAgo(comment.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.25))

                    // Like comment
                    Button {
                        toggleLike()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.system(size: 9))
                            if likes > 0 {
                                Text("\(likes)")
                                    .font(.system(size: 9))
                            }
                        }
                        .foregroundStyle(liked ? Color.red.opacity(0.8) : Color.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)

                    if depth < 2 {
                        Button {
                            guard auth.isAuthenticated else { return }
                            withAnimation { replyOpen.toggle() }
                        } label: {
                            Text("Reply")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Reply input
                if replyOpen {
                    HStack(spacing: 6) {
                        TextField("Reply to \(comment.user?.name ?? "User")…", text: $replyText)
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button {
                            Task { await submitReply() }
                        } label: {
                            Text("Send")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(C.bg)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(C.watch)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                        .buttonStyle(.plain)

                        Button {
                            replyOpen = false
                            replyText = ""
                        } label: {
                            Text("✕")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                ForEach(comment.replies ?? []) { reply in
                    PostCommentRow(postId: postId, comment: reply, depth: depth + 1, onReplyAdded: onReplyAdded)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, depth > 0 ? 20 : 0)
    }

    private func toggleLike() {
        guard auth.isAuthenticated else { return }
        let newLiked = !liked
        liked = newLiked
        likes = max(0, likes + (newLiked ? 1 : -1))
        Task {
            _ = try? await APIClient.shared.likePostComment(postId: postId, commentId: comment.id, liked: newLiked)
        }
    }

    private func submitReply() async {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending else { return }
        sending = true
        do {
            let reply = try await APIClient.shared.createPostComment(postId: postId, content: text, parentId: comment.id)
            await MainActor.run {
                onReplyAdded(comment.id, reply)
                replyText = ""
                replyOpen = false
            }
        } catch {}
        sending = false
    }
}

// MARK: - Inline comments for a post

private struct PostCommentsView: View {
    let postId: String

    @State private var comments: [PostComment] = []
    @State private var loading = true
    @State private var fetchError = false
    @State private var newText = ""
    @State private var submitting = false

    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(C.borderSubtle)

            // New comment input
            HStack(spacing: 6) {
                TextField(auth.isAuthenticated ? "Add a comment…" : "Sign in to comment",
                          text: $newText, axis: .vertical)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(!auth.isAuthenticated)

                if auth.isAuthenticated {
                    Button {
                        Task { await submitComment() }
                    } label: {
                        Text("Post")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(C.bg)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(C.watch)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                    .buttonStyle(.plain)
                }
            }

            // Comment list
            if loading {
                Text("Loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
            } else if fetchError {
                Text("Could not load comments.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
            } else if comments.isEmpty {
                Text("No comments yet. Be the first!")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(comments) { c in
                        PostCommentRow(postId: postId, comment: c, onReplyAdded: addReply)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        .task { await loadComments() }
    }

    private func loadComments() async {
        loading = true; fetchError = false
        do {
            let fetchedComments = try await APIClient.shared.fetchPostComments(postId: postId)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                comments = fetchedComments
            }
        } catch {
            fetchError = true
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            loading = false
        }
    }

    private func submitComment() async {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !submitting else { return }
        submitting = true
        do {
            let c = try await APIClient.shared.createPostComment(postId: postId, content: text)
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    comments.append(c)
                    newText = ""
                }
            }
        } catch {}
        submitting = false
    }

    private func addReply(parentId: String, reply: PostComment) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            comments = comments.map { $0.addingReply(reply, to: parentId) }
        }
    }
}

private extension PostComment {
    func addingReply(_ reply: PostComment, to parentId: String) -> PostComment {
        if id == parentId {
            return PostComment(
                id: id,
                userId: userId,
                content: content,
                likes: likes,
                parentId: self.parentId,
                createdAt: createdAt,
                user: user,
                replies: (replies ?? []) + [reply]
            )
        }

        return PostComment(
            id: id,
            userId: userId,
            content: content,
            likes: likes,
            parentId: self.parentId,
            createdAt: createdAt,
            user: user,
            replies: replies?.map { $0.addingReply(reply, to: parentId) }
        )
    }
}

// MARK: - Single post card

private struct PostCard: View {
    let post: UserPost
    let target: PostSectionTarget
    let onSeek: ((Double) -> Void)?
    let onDelete: (String) -> Void
    let onLikeToggle: (String) -> Void

    @State private var showComments = false
    @State private var spoilerRevealed = false

    @EnvironmentObject private var auth: AuthManager

    // Thumbnail dimensions (matching web: 148px wide, 16:9 = 83px tall)
    private let thumbW: CGFloat = 148
    private var thumbH: CGFloat { (thumbW * 9 / 16).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Main row ─────────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {
                // Thumbnail
                thumbnailArea
                    .frame(width: thumbW, height: thumbH)
                    .clipShape(RoundedRectangle(cornerRadius: 0))

                // Content: user + caption + actions
                contentArea
            }

            // Collapsible comments
            if showComments {
                PostCommentsView(postId: post.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 0.5) }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showComments)
    }

    // MARK: Thumbnail

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack(alignment: .bottomTrailing) {
            // Spoiler cover
            if post.isSpoiler && !spoilerRevealed {
                Color.black.opacity(0.75)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.35))
                            Text("Spoiler")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.35))
                                .tracking(1)
                        }
                    }
                    .onTapGesture { withAnimation { spoilerRevealed = true } }
            } else {
                if let videoURL = clipVideoURL {
                    ClipFrameThumbnail(url: videoURL, seconds: Double(post.markIn))
                } else if let fallbackURL = clipFallbackThumbnailURL {
                    AsyncImage(url: fallbackURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.black.opacity(0.4)
                    }
                } else {
                    Color.black.opacity(0.4)
                }

                // Clip timestamp badge
                HStack(spacing: 2) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 6))
                    Text("\(fmtSec(post.markIn))–\(fmtSec(post.markOut))")
                        .font(.system(size: 8, weight: .semibold))
                        .fontDesign(.monospaced)
                    Text("(\(fmtSec(post.markOut - post.markIn)))")
                        .font(.system(size: 7))
                        .opacity(0.6)
                }
                .foregroundStyle(C.bg)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(C.watch)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(4)

                // Tap to seek
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSeek?(Double(post.markIn))
                    }

                // Play overlay hint
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private var clipVideoURL: URL? {
        C.mediaURL(post.video?.videoUrl ?? post.episode?.videoUrl)
    }

    private var clipFallbackThumbnailURL: URL? {
        C.mediaURL(
            post.video?.thumbnailUrl
                ?? post.episode?.thumbnailUrl
                ?? post.episode?.season?.show?.coverUrl
        )
    }

    // MARK: Content

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            // User row
            HStack(alignment: .center, spacing: 6) {
                // Avatar
                Circle()
                    .fill(C.elevated)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if let img = post.user?.image, let url = URL(string: img) {
                            AsyncImage(url: url) { i in i.resizable().scaledToFill() } placeholder: { EmptyView() }
                                .clipShape(Circle())
                        } else {
                            Text(String((post.user?.name ?? "?").prefix(1)).uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(C.watch)
                        }
                    }

                Text(post.user?.name ?? "User")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(timeAgo(post.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.horizontal, 12).padding(.top, 10)

            // Caption
            if let caption = post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(3)
                    .lineSpacing(3)
                    .padding(.horizontal, 12).padding(.top, 6)
            }

            Spacer(minLength: 4)

            // Action strip
            HStack(spacing: 2) {
                // Like
                Button {
                    onLikeToggle(post.id)
                } label: {
                    HStack(alignment: .center, spacing: 5) {
                        Image(systemName: post.myLike ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 18, height: 18, alignment: .center)
                        if post.likeCount > 0 {
                            Text("\(post.likeCount)")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(height: 18, alignment: .center)
                        }
                    }
                    .frame(height: 22, alignment: .center)
                    .foregroundStyle(post.myLike ? Color(red: 1, green: 0.28, blue: 0.34) : Color.white.opacity(0.48))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                // Comment
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showComments.toggle() }
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22, alignment: .center)
                        .foregroundStyle(showComments ? Color.white.opacity(0.86) : Color.white.opacity(0.48))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                // Share
                Button {
                    sharePost()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22, alignment: .center)
                        .foregroundStyle(Color.white.opacity(0.48))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                // Delete (own post only)
                if auth.currentUser?.id == post.userId {
                    Spacer()
                    Button {
                        onDelete(post.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 22, height: 22, alignment: .center)
                            .foregroundStyle(Color.white.opacity(0.28))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sharePost() {
        let path: String
        switch target {
        case .video(let id):
            path = "/watch/\(id)?t=\(post.markIn)&out=\(post.markOut)"
        case .episode(let id):
            path = "/watch/episode/\(id)?t=\(post.markIn)&out=\(post.markOut)"
        }
        guard let shareURL = URL(string: C.baseURL + path) else { return }
        let av = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}

private struct ClipFrameThumbnail: View {
    let url: URL
    let seconds: Double

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black.opacity(0.4)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(failed ? 0.22 : 0.34))
                            .offset(x: 1)
                    }
            }
        }
        .task(id: "\(url.absoluteString)-\(seconds)") {
            await loadFrame()
        }
    }

    private func loadFrame() async {
        failed = false
        image = nil

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.6, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.6, preferredTimescale: 600)

        do {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image
            await MainActor.run {
                image = UIImage(cgImage: cgImage)
            }
        } catch {
            await MainActor.run {
                failed = true
            }
        }
    }
}

// MARK: - PostSectionView (main export)

struct PostSectionView: View {
    let target: PostSectionTarget
    var reloadToken: Int = 0
    var insertedPostToken: Int = 0
    var insertedPost: UserPost?
    var previewLimit: Int? = nil
    var startsExpanded: Bool = false
    var onShowMore: ((Int) -> Void)? = nil
    let onSeek: ((Double) -> Void)?

    private let pageSize = 12

    @State private var posts: [UserPost] = []
    @State private var loading = true
    @State private var expanded: Bool
    @State private var visibleCount = 12

    @EnvironmentObject private var auth: AuthManager

    private var contentAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.88)
    }

    init(
        target: PostSectionTarget,
        reloadToken: Int = 0,
        insertedPostToken: Int = 0,
        insertedPost: UserPost? = nil,
        previewLimit: Int? = nil,
        startsExpanded: Bool = false,
        onShowMore: ((Int) -> Void)? = nil,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.target = target
        self.reloadToken = reloadToken
        self.insertedPostToken = insertedPostToken
        self.insertedPost = insertedPost
        self.previewLimit = previewLimit
        self.startsExpanded = startsExpanded
        self.onShowMore = onShowMore
        self.onSeek = onSeek
        _expanded = State(initialValue: startsExpanded || previewLimit != nil)
    }

    var body: some View {
        // Hidden while loading resolves to empty (matching web: returns null)
        if loading || !posts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().background(C.border)
                    .padding(.bottom, 16)

                // ── Toggle header ────────────────────────────────────────────
                HStack(spacing: 8) {
                    Button {
                        guard !loading && !posts.isEmpty else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(loading ? "Clip reactions"
                                 : "\(posts.count) Clip reaction\(posts.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.4))
                                .textCase(.uppercase)
                                .tracking(0.5)

                            if !loading && !posts.isEmpty {
                                // Green badge (matches web style={{ background: "var(--watch)" }})
                                Text("\(posts.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(C.bg)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(C.watch)
                                    .clipShape(Capsule())

                                // Chevron
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.4))
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                                    .animation(.easeInOut(duration: 0.2), value: expanded)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if !auth.isAuthenticated {
                        Button { } label: {
                            Text("Sign in to post")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // ── Expanded content ─────────────────────────────────────────
                if expanded || previewLimit != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if loading {
                            // Skeleton matching card height
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(C.surface)
                                    .frame(height: 83)
                                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 0.5) }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        } else {
                            ForEach(visiblePosts) { post in
                                PostCard(post: post, target: target, onSeek: onSeek, onDelete: deletePost, onLikeToggle: toggleLike)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }

                            // Load more
                            if let previewLimit, posts.count > previewLimit {
                                Button {
                                    onShowMore?(posts.count)
                                } label: {
                                    HStack {
                                        Text("Show \(posts.count - previewLimit) more reaction\(posts.count - previewLimit == 1 ? "" : "s")")
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
                            } else if visibleCount < posts.count {
                                Button {
                                    visibleCount += pageSize
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("Show \(posts.count - visibleCount) more")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.white.opacity(0.4))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(C.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 0.5) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(contentAnimation, value: expanded)
            .animation(contentAnimation, value: loading)
            .animation(contentAnimation, value: postIdentity)
            .task { await loadPosts() }
            .onChange(of: reloadToken) { _, _ in
                Task { await loadPosts(expandAfterLoad: true) }
            }
            .onChange(of: insertedPostToken) { _, _ in
                guard let insertedPost else { return }
                upsertInsertedPost(insertedPost)
            }
        }
    }

    private var visiblePosts: [UserPost] {
        if let previewLimit {
            return Array(posts.prefix(previewLimit))
        }
        return Array(posts.prefix(visibleCount))
    }

    private var postIdentity: String {
        posts.map(\.id).joined(separator: "|")
    }

    @MainActor
    private func loadPosts(expandAfterLoad: Bool = false) async {
        withAnimation(.easeOut(duration: 0.16)) {
            loading = true
        }
        do {
            let fetchedPosts: [UserPost]
            switch target {
            case .video(let id):
                fetchedPosts = try await APIClient.shared.fetchPosts(videoId: id)
            case .episode(let id):
                fetchedPosts = try await APIClient.shared.fetchPosts(episodeId: id)
            }
            withAnimation(contentAnimation) {
                posts = fetchedPosts
                if expandAfterLoad, !fetchedPosts.isEmpty {
                    expanded = true
                    visibleCount = max(visibleCount, min(pageSize, fetchedPosts.count))
                }
                loading = false
            }
        } catch {
            withAnimation(contentAnimation) {
                loading = false
            }
        }
    }

    private func deletePost(_ id: String) {
        Task {
            try? await APIClient.shared.deletePost(postId: id)
            await MainActor.run {
                withAnimation(contentAnimation) {
                    posts.removeAll { $0.id == id }
                }
            }
        }
    }

    private func toggleLike(_ id: String) {
        guard auth.isAuthenticated else { return }
        // Optimistic update
        posts = posts.map { p in
            guard p.id == id else { return p }
            return UserPost(
                id: p.id, userId: p.userId, markIn: p.markIn, markOut: p.markOut,
                caption: p.caption, isSpoiler: p.isSpoiler, createdAt: p.createdAt,
                likeCount: p.likeCount + (p.myLike ? -1 : 1),
                myLike: !p.myLike, user: p.user
            )
        }
        Task {
            guard let resp = try? await APIClient.shared.togglePostLike(postId: id) else {
                // Revert on failure
                await MainActor.run {
                    posts = posts.map { p in
                        guard p.id == id else { return p }
                        return UserPost(
                            id: p.id, userId: p.userId, markIn: p.markIn, markOut: p.markOut,
                            caption: p.caption, isSpoiler: p.isSpoiler, createdAt: p.createdAt,
                            likeCount: p.likeCount + (p.myLike ? 1 : -1),
                            myLike: !p.myLike, user: p.user
                        )
                    }
                }
                return
            }
            await MainActor.run {
                posts = posts.map { p in
                    guard p.id == id else { return p }
                    return UserPost(
                        id: p.id, userId: p.userId, markIn: p.markIn, markOut: p.markOut,
                        caption: p.caption, isSpoiler: p.isSpoiler, createdAt: p.createdAt,
                        likeCount: resp.likeCount, myLike: resp.liked, user: p.user
                    )
                }
            }
        }
    }

    private func upsertInsertedPost(_ post: UserPost) {
        withAnimation(contentAnimation) {
            posts.removeAll { $0.id == post.id }
            posts.append(post)
            posts.sort { $0.markIn < $1.markIn }
            expanded = true
            visibleCount = max(visibleCount, min(pageSize, posts.count))
            loading = false
        }
    }
}
