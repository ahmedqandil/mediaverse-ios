import SwiftUI
import UIKit

@MainActor
final class SocialFeedAutoplayController: ObservableObject {
    @Published var activeVideoID: String?
    @Published private(set) var isPreservingHandoff = false

    let previewManager = FeedPreviewPlayerManager()

    private var frames: [String: CGRect] = [:]
    private var updateTask: Task<Void, Never>?
    private var suppressedVideoID: String?

    func update(frames: [String: CGRect], ripples: [Ripple], blocked: Bool) {
        let videos = feedVideos(in: ripples)
        self.frames = frames
        updateTask?.cancel()
        previewManager.warm(videos: videos, currentID: activeVideoID)

        guard !blocked else {
            isPreservingHandoff = false
            activeVideoID = nil
            previewManager.pause()
            return
        }
        if activeVideoID != nil {
            isPreservingHandoff = true
            activeVideoID = nil
            previewManager.pausePreservingHandoff()
        }
        previewManager.prebufferBottomCandidates(videos: videos, frames: frames)
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled, let self else { return }
            self.selectPreview(from: videos)
            self.updateTask = nil
        }
    }

    func suppressAndReselect(videoID: String, ripples: [Ripple], blocked: Bool) {
        suppressedVideoID = videoID
        update(frames: frames, ripples: ripples, blocked: blocked)
    }

    func setBlocked(_ blocked: Bool, ripples: [Ripple]) {
        update(frames: frames, ripples: ripples, blocked: blocked)
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        activeVideoID = nil
        isPreservingHandoff = false
        previewManager.pause()
    }

    private func selectPreview(from videos: [FeedVideo]) {
        isPreservingHandoff = false
        let policy = FeedPreviewAutoplayPolicy()
        let videosByID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidate = videos.compactMap { video -> (String, URL, CGFloat)? in
            guard video.id != suppressedVideoID,
                  let frame = frames[video.id],
                  let url = C.mediaURL(videosByID[video.id]?.videoUrl),
                  let score = policy.candidateScore(for: frame)
            else { return nil }
            return (video.id, url, score)
        }
        .max { $0.2 < $1.2 }

        guard let candidate else {
            activeVideoID = nil
            previewManager.pause()
            return
        }
        suppressedVideoID = nil
        activeVideoID = candidate.0
        previewManager.warm(videos: videos, currentID: candidate.0)
        previewManager.play(videoId: candidate.0, url: candidate.1)
    }

    private func feedVideos(in ripples: [Ripple]) -> [FeedVideo] {
        ripples.flatMap { ripple in
            ripple.attachments.compactMap { $0.video?.feedVideo }
        }
    }
}

struct RippleCardActions {
    var addEnergy: (() -> Void)?
    var comment: (() -> Void)?
    var echo: (() -> Void)?
    var share: (() -> Void)?
    var openAuthor: (() -> Void)?
    var openVibe: (() -> Void)?
    var togglePin: (() -> Void)?
    var isPinned = false
    var pinTarget = "Atmo"
    var edit: (() -> Void)?
    var delete: (() -> Void)?
    var report: (() -> Void)?
    var canManageQuestionAnswers = false

    static let readOnly = RippleCardActions()
}

struct RippleCard: View {
    let ripple: Ripple
    let actions: RippleCardActions
    let allowsEngagement: Bool
    @Binding private var activePreviewVideoId: String?
    private let previewManager: FeedPreviewPlayerManager?
    private let isAutoplayBlocked: Bool
    private let isPreservingPreviewHandoff: Bool
    private let onPreviewPaused: (String) -> Void
    private let onVideoHandoff: (FeedVideo, CGRect?) -> Void
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var engagement: RippleEngagementController
    @State private var showsEnergy = false
    @State private var showsShare = false
    @State private var showsComments = false
    @State private var showsEcho = false
    @State private var showsEdit = false
    @State private var showsReport = false
    @State private var confirmsDelete = false
    @State private var isDeleted = false
    @State private var isBodyExpanded = false
    @State private var editedBody: String?
    @State private var editedSpoiler: Bool?
    @State private var editedCommentsDisabled: Bool?
    @State private var displayedCommentCount: Int
    @State private var isResourceBookmarked: Bool
    @State private var isUpdatingResourceBookmark = false
    @State private var specializedError: String?
    @State private var displayedQuestionStatus: String?
    @State private var displayedAcceptedAnswerId: String?
    @State private var isUpdatingAcceptedAnswer = false

    init(
        ripple: Ripple,
        actions: RippleCardActions = .readOnly,
        allowsEngagement: Bool = false,
        activePreviewVideoId: Binding<String?> = .constant(nil),
        previewManager: FeedPreviewPlayerManager? = nil,
        isAutoplayBlocked: Bool = true,
        isPreservingPreviewHandoff: Bool = false,
        onPreviewPaused: @escaping (String) -> Void = { _ in },
        onVideoHandoff: @escaping (FeedVideo, CGRect?) -> Void = { _, _ in }
    ) {
        self.ripple = ripple
        self.actions = actions
        self.allowsEngagement = allowsEngagement
        _activePreviewVideoId = activePreviewVideoId
        self.previewManager = previewManager
        self.isAutoplayBlocked = isAutoplayBlocked
        self.isPreservingPreviewHandoff = isPreservingPreviewHandoff
        self.onPreviewPaused = onPreviewPaused
        self.onVideoHandoff = onVideoHandoff
        _engagement = StateObject(wrappedValue: RippleEngagementController(ripple: ripple))
        _displayedCommentCount = State(initialValue: ripple.commentCount)
        _isResourceBookmarked = State(initialValue: ripple.bookmarked)
        _displayedQuestionStatus = State(initialValue: ripple.questionStatus)
        _displayedAcceptedAnswerId = State(initialValue: ripple.acceptedAnswerId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if let body = (editedBody ?? ripple.body)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                MentionText(
                    plain: body,
                    html: nil,
                    font: bodyFont(hasAttachments: !ripple.attachments.isEmpty || ripple.poll != nil),
                    color: C.text
                )
                    .lineLimit(isBodyExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                if body.count > 180 {
                    Button(isBodyExpanded ? "Show less" : "More") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isBodyExpanded.toggle()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }

            if let poll = engagement.poll {
                RipplePollCard(
                    poll: poll,
                    allowsVoting: allowsEngagement && !engagement.isBusy,
                    isSaving: engagement.isBusy
                ) { optionIds in
                    Task { await engagement.vote(optionIds: optionIds) }
                }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if ripple.wave?.type == .questions || ripple.wave?.type == .resources {
                specializedWaveMetadata
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if !ripple.attachments.isEmpty {
                RippleAttachmentsView(
                    attachments: ripple.attachments,
                    activePreviewVideoId: $activePreviewVideoId,
                    previewManager: previewManager,
                    isAutoplayBlocked: isAutoplayBlocked,
                    isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                    onPreviewPaused: onPreviewPaused,
                    onVideoHandoff: onVideoHandoff
                )
                    .padding(.vertical, 14)
            }

            if engagement.energyCount > 0 {
                SocialEnergyMeter(
                    total: engagement.energyTotal,
                    count: engagement.energyCount,
                    tags: engagement.energyTags
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            actionBar
                .padding(.horizontal, 4)
                .padding(.vertical, 5)

            if showsComments {
                Divider().background(C.borderSubtle)
                CommentThreadView(
                    target: .ripple(ripple.id),
                    inputPosition: .top,
                    showsHeader: true,
                    autoFocusComposer: true,
                    onCountChange: { displayedCommentCount = $0 },
                    acceptedAnswerId: displayedAcceptedAnswerId,
                    canManageAcceptedAnswer: canManageQuestionAnswer,
                    onAcceptAnswer: { commentId in
                        try await acceptQuestionAnswer(commentId: commentId)
                    }
                )
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface.opacity(0.82))
        .overlay {
            if horizontalSizeClass == .compact {
                VStack(spacing: 0) {
                    Rectangle().fill(C.borderSubtle).frame(height: 1)
                    Spacer()
                    Rectangle().fill(C.borderSubtle).frame(height: 1)
                }
            } else {
                RoundedRectangle(cornerRadius: C.cardRadius)
                    .stroke(C.borderSubtle, lineWidth: 1)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: horizontalSizeClass == .compact ? 0 : C.cardRadius,
                style: .continuous
            )
        )
        .frame(height: isDeleted ? 0 : nil)
        .opacity(isDeleted ? 0 : 1)
        .clipped()
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showsEnergy) {
            RippleEnergySheet(controller: engagement)
                .presentationDetents([.height(610), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showsShare) {
            if let shareURL {
                NativeShareSheet(items: [shareURL])
                    .ignoresSafeArea()
                    .onAppear {
                        Task { await engagement.recordNativeShare() }
                    }
            }
        }
        .sheet(isPresented: $showsEcho) {
            EchoVibeSheet(ripple: ripple) { added in
                engagement.addEchoes(added)
            }
            .presentationDetents([.height(610), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsEdit) {
            RippleEditSheet(
                ripple: ripple,
                initialBody: editedBody ?? ripple.body ?? "",
                initialSpoiler: editedSpoiler ?? ripple.isSpoiler,
                initialCommentsDisabled: editedCommentsDisabled ?? ripple.commentsDisabled
            ) { updated in
                editedBody = updated.body
                editedSpoiler = updated.isSpoiler
                editedCommentsDisabled = updated.commentsDisabled
            }
        }
        .sheet(isPresented: $showsReport) {
            if let slug = ripple.club?.slug {
                RippleReportSheet(postId: ripple.id, vibeSlug: slug)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            "Delete this Ripple?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Ripple", role: .destructive) {
                Task { await deleteRipple() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Ripple and cannot be undone.")
        }
        .alert(
            "Ripple update failed",
            isPresented: Binding(
                get: { engagement.errorMessage != nil },
                set: { if !$0 { engagement.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engagement.errorMessage ?? "")
        }
        .alert(
            "Resource update failed",
            isPresented: Binding(
                get: { specializedError != nil },
                set: { if !$0 { specializedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(specializedError ?? "")
        }
    }

    @ViewBuilder
    private var specializedWaveMetadata: some View {
        if ripple.wave?.type == .questions {
            HStack(spacing: 8) {
                Image(systemName: displayedQuestionStatus == "ANSWERED"
                    ? "checkmark.seal.fill"
                    : "questionmark.bubble.fill")
                Text(displayedQuestionStatus == "ANSWERED" ? "Answered Question" : "Open Question")
                    .font(.caption.weight(.semibold))
                Spacer()
                if displayedQuestionStatus == "ANSWERED", canManageQuestionAnswer {
                    Button(isUpdatingAcceptedAnswer ? "Reopening…" : "Reopen") {
                        Task { await reopenQuestion() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .disabled(isUpdatingAcceptedAnswer)
                }
            }
            .foregroundStyle(displayedQuestionStatus == "ANSWERED" ? Color.green : C.watch)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background((ripple.questionStatus == "ANSWERED" ? Color.green : C.watch).opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(ripple.questionStatus == "ANSWERED" ? "Answered Question" : "Open Question")
        } else if ripple.wave?.type == .resources {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .foregroundStyle(C.watch)
                Text(ripple.resourceCategory ?? "Resource")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                Spacer()
                if allowsEngagement && auth.isAuthenticated {
                    Button {
                        Task { await toggleResourceBookmark() }
                    } label: {
                        Label(
                            isResourceBookmarked ? "Saved" : "Save",
                            systemImage: isResourceBookmarked ? "bookmark.fill" : "bookmark"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isResourceBookmarked ? C.watch : C.text)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingResourceBookmark)
                    .accessibilityLabel(isResourceBookmarked ? "Remove Resource bookmark" : "Bookmark Resource")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(C.elevated.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var canManageQuestionAnswer: Bool {
        guard ripple.wave?.type == .questions else { return false }
        return SpecializedWaveUIRules.canManageQuestionAnswer(
            isAuthor: auth.currentUser?.id == ripple.author.id,
            canModerate: actions.canManageQuestionAnswers
        )
    }

    @MainActor
    private func acceptQuestionAnswer(commentId: String) async throws {
        guard canManageQuestionAnswer, !isUpdatingAcceptedAnswer else { return }
        isUpdatingAcceptedAnswer = true
        defer { isUpdatingAcceptedAnswer = false }
        let result = try await LegacySocialAPIAdapter(
            transport: APIClient.shared
        ).acceptQuestionAnswer(postId: ripple.id, commentId: commentId)
        displayedAcceptedAnswerId = result.acceptedAnswerId
        displayedQuestionStatus = result.questionStatus
    }

    @MainActor
    private func reopenQuestion() async {
        guard canManageQuestionAnswer, !isUpdatingAcceptedAnswer else { return }
        isUpdatingAcceptedAnswer = true
        defer { isUpdatingAcceptedAnswer = false }
        do {
            let result = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).reopenQuestion(postId: ripple.id)
            displayedAcceptedAnswerId = result.acceptedAnswerId
            displayedQuestionStatus = result.questionStatus
        } catch {
            specializedError = socialErrorMessage(error)
        }
    }

    @MainActor
    private func toggleResourceBookmark() async {
        guard !isUpdatingResourceBookmark else { return }
        isUpdatingResourceBookmark = true
        defer { isUpdatingResourceBookmark = false }
        do {
            isResourceBookmarked = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).setResourceBookmarked(
                postId: ripple.id,
                bookmarked: !isResourceBookmarked
            )
        } catch {
            specializedError = socialErrorMessage(error)
        }
    }

    private var identityHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            authorTarget {
                SocialIdentityAvatar(
                    image: ripple.author.image,
                    name: ripple.author.name ?? ripple.author.handle,
                    size: 36
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                authorTarget {
                    Text(ripple.author.name ?? ripple.author.handle.map { "@\($0)" } ?? "Westreem user")
                        .font(.subheadline.bold())
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    if let handle = ripple.author.handle, ripple.author.name != nil {
                        Text("@\(handle)")
                    }
                    if let club = ripple.club {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        vibeTarget(club) {
                            Text(club.name)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsActionMenu {
                Menu {
                    if let togglePin = actions.togglePin {
                        Button(
                            actions.isPinned ? "Unpin from \(actions.pinTarget)" : "Pin to \(actions.pinTarget)",
                            systemImage: actions.isPinned ? "pin.slash" : "pin",
                            action: togglePin
                        )
                    }
                    if let editAction {
                        Button("Edit", systemImage: "pencil", action: editAction)
                    }
                    if let deleteAction {
                        Button("Delete", systemImage: "trash", role: .destructive, action: deleteAction)
                    }
                    if let reportAction {
                        Button("Report", systemImage: "flag", action: reportAction)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.textMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private var isOwner: Bool {
        auth.currentUser?.id == ripple.author.id
    }

    private var editAction: (() -> Void)? {
        actions.edit ?? (allowsEngagement && isOwner ? { showsEdit = true } : nil)
    }

    private var deleteAction: (() -> Void)? {
        actions.delete ?? (allowsEngagement && isOwner ? { confirmsDelete = true } : nil)
    }

    private var reportAction: (() -> Void)? {
        actions.report ?? (
            allowsEngagement && !isOwner && ripple.club?.slug != nil
                ? { showsReport = true }
                : nil
        )
    }

    private var showsActionMenu: Bool {
        actions.togglePin != nil || editAction != nil || deleteAction != nil || reportAction != nil
    }

    @MainActor
    private func deleteRipple() async {
        do {
            try await LegacySocialAPIAdapter(transport: APIClient.shared)
                .deleteRipple(postId: ripple.id)
            withAnimation(.easeOut(duration: 0.2)) {
                isDeleted = true
            }
        } catch {
            engagement.errorMessage = socialErrorMessage(error)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            action(
                title: "Add Energy",
                systemImage: "bolt.fill",
                count: engagement.energyCount,
                handler: actions.addEnergy ?? (allowsEngagement ? { showsEnergy = true } : nil)
            )
            action(
                title: "Comment",
                systemImage: "bubble.left",
                count: displayedCommentCount,
                handler: actions.comment ?? (
                    allowsEngagement && !(editedCommentsDisabled ?? ripple.commentsDisabled)
                        ? { withAnimation(.easeInOut(duration: 0.2)) { showsComments.toggle() } }
                        : nil
                )
            )
            action(
                title: "Echo",
                systemImage: "dot.radiowaves.left.and.right",
                count: engagement.echoCount,
                handler: actions.echo ?? (allowsEngagement ? { showsEcho = true } : nil)
            )
            action(
                title: "Share",
                systemImage: "square.and.arrow.up",
                count: engagement.shareCount,
                handler: actions.share ?? (allowsEngagement && shareURL != nil ? { showsShare = true } : nil)
            )
        }
        .overlay(alignment: .top) {
            Rectangle().fill(C.borderSubtle).frame(height: 1)
        }
    }

    private func action(
        title: String,
        systemImage: String,
        count: Int,
        handler: (() -> Void)?
    ) -> some View {
        Button(action: { handler?() }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(count > 0 ? "\(title) · \(count)" : title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(handler == nil ? C.textTertiary : C.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(handler == nil)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    private func bodyFont(hasAttachments: Bool) -> Font {
        hasAttachments ? .body : .system(size: 20, weight: .medium, design: .rounded)
    }

    @ViewBuilder
    private func authorTarget<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let openAuthor = actions.openAuthor {
            Button(action: openAuthor, label: content).buttonStyle(.plain)
        } else if let handle = ripple.author.handle {
            NavigationLink(value: AppRoute.atmo(handle), label: content).buttonStyle(.plain)
        } else {
            content()
        }
    }

    @ViewBuilder
    private func vibeTarget<Content: View>(
        _ club: VibeSummary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let openVibe = actions.openVibe {
            Button(action: openVibe, label: content).buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.vibe(club.slug), label: content).buttonStyle(.plain)
        }
    }

    private var shareURL: URL? {
        guard let slug = ripple.club?.slug else { return nil }
        return URL(string: "\(C.baseURL)/vibes/\(C.pathSegment(slug))/posts/\(C.pathSegment(ripple.id))")
    }
}

struct SocialIdentityAvatar: View {
    let image: String?
    let name: String?
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(C.elevated)
            .frame(width: size, height: size)
            .overlay {
                if let url = C.mediaURL(image) {
                    CachedRemoteImage(
                        url: url,
                        targetSize: CGSize(width: size, height: size)
                    ) { loaded in
                        loaded.resizable().scaledToFill()
                    } placeholder: {
                        initials
                    }
                } else {
                    initials
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(C.border, lineWidth: 1))
    }

    private var initials: some View {
        Text(String((name?.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "W")).uppercased())
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(C.textMuted)
    }
}

private struct RippleEditSheet: View {
    let ripple: Ripple
    let onSaved: (EditedRipplePost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText: String
    @State private var isSpoiler: Bool
    @State private var commentsDisabled: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    init(
        ripple: Ripple,
        initialBody: String,
        initialSpoiler: Bool,
        initialCommentsDisabled: Bool,
        onSaved: @escaping (EditedRipplePost) -> Void
    ) {
        self.ripple = ripple
        self.onSaved = onSaved
        _bodyText = State(initialValue: initialBody)
        _isSpoiler = State(initialValue: initialSpoiler)
        _commentsDisabled = State(initialValue: initialCommentsDisabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ripple") {
                    TextField("What’s the energy?", text: $bodyText, axis: .vertical)
                        .lineLimit(4...12)
                        .westreemField(minHeight: 104)
                    Toggle("Spoiler", isOn: $isSpoiler)
                    Toggle("Disable comments", isOn: $commentsDisabled)
                }
                .westreemFormRow()
                Section {
                    Text("Existing photos, media, polls, and Echo attachments are preserved and cannot be changed here.")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                .westreemFormRow()
            }
            .westreemFormStyle()
            .navigationTitle("Edit Ripple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .alert(
                "Ripple could not be edited",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        do {
            let updated = try await api.editRipple(
                postId: ripple.id,
                body: bodyText,
                isSpoiler: isSpoiler,
                commentsDisabled: commentsDisabled
            )
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isSaving = false
    }
}

struct RippleReportSheet: View {
    let postId: String
    let vibeSlug: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: String?
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var detailsFocused: Bool
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)
    private let reasons = [
        "Spam or scam",
        "Harassment or bullying",
        "Hate speech",
        "Violence or dangerous content",
        "Sexual content",
        "Misinformation",
        "Copyright or impersonation",
        "Something else"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Why are you reporting this Ripple?")
                            .font(.title3.bold())
                            .foregroundStyle(C.text)
                        Text("Your report is private. The Vibe’s moderation team will review it.")
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        ForEach(reasons, id: \.self) { reason in
                            Button {
                                C.lightHaptic()
                                selectedReason = reason
                                if reason == "Something else" {
                                    detailsFocused = true
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Text(reason)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(C.text)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: selectedReason == reason ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(selectedReason == reason ? C.watch : C.textTertiary)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                                .background(selectedReason == reason ? C.watch.opacity(0.10) : C.elevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            selectedReason == reason ? C.watch.opacity(0.65) : C.borderSubtle,
                                            lineWidth: 1
                                        )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(selectedReason == "Something else" ? "Tell us what happened" : "Additional details")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(C.textMuted)
                            Spacer()
                            Text("\(details.count)/2000")
                                .font(.caption2)
                                .foregroundStyle(details.count > 2_000 ? .red : C.textTertiary)
                        }
                        TextField(
                            "",
                            text: $details,
                            prompt: Text("Optional context for the moderators").foregroundStyle(C.textTertiary),
                            axis: .vertical
                        )
                        .focused($detailsFocused)
                        .lineLimit(4...8)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(C.text)
                        .tint(C.watch)
                        .padding(12)
                        .frame(minHeight: 108, alignment: .topLeading)
                        .background(C.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(detailsFocused ? C.watch.opacity(0.65) : C.borderSubtle)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        detailsFocused = false
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "flag.fill")
                                Text("Submit report")
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(C.watch)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.45)
                }
                .padding(C.pagePad)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Report Ripple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Report could not be submitted",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canSubmit: Bool {
        guard !isSubmitting, selectedReason != nil, details.count <= 2_000 else { return false }
        if selectedReason == "Something else" {
            return details.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        }
        return true
    }

    @MainActor
    private func submit() async {
        guard canSubmit, let selectedReason else { return }
        isSubmitting = true
        do {
            _ = try await api.reportRipple(
                postId: postId,
                vibeSlug: vibeSlug,
                reason: selectedReason,
                details: details
            )
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isSubmitting = false
    }
}

private struct RippleAttachmentsView: View {
    let attachments: [RippleAttachment]
    @Binding var activePreviewVideoId: String?
    let previewManager: FeedPreviewPlayerManager?
    let isAutoplayBlocked: Bool
    let isPreservingPreviewHandoff: Bool
    let onPreviewPaused: (String) -> Void
    let onVideoHandoff: (FeedVideo, CGRect?) -> Void

    private var photos: [RippleAttachment] {
        attachments.filter { $0.type == .photo && $0.imageURL != nil }
    }

    private var other: [RippleAttachment] {
        attachments.filter { $0.type != .photo || $0.imageURL == nil }
    }

    var body: some View {
        VStack(spacing: 10) {
            if !photos.isEmpty {
                RipplePhotoCarousel(photos: photos)
            }
            ForEach(other) { attachment in
                attachmentView(attachment)
            }
        }
    }

    @ViewBuilder
    private func attachmentView(_ attachment: RippleAttachment) -> some View {
        switch attachment.type {
        case .link:
            RippleLinkAttachment(attachment: attachment)
                .padding(.horizontal, 14)
        case .westreemVideo:
            if let video = attachment.video {
                RippleVideoAttachmentView(
                    video: video,
                    activePreviewVideoId: $activePreviewVideoId,
                    previewManager: previewManager,
                    isAutoplayBlocked: isAutoplayBlocked,
                    isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                    onPreviewPaused: onPreviewPaused,
                    onVideoHandoff: onVideoHandoff
                )
            }
        case .westreemCollection:
            if let collection = attachment.collection {
                RippleCollectionAttachmentView(collection: collection)
                    .padding(.horizontal, 14)
            }
        case .westreemClip:
            if let clip = attachment.userPost {
                RippleClipAttachmentView(clip: clip)
                    .padding(.horizontal, 14)
            }
        case .westreemRipple:
            if let echoed = attachment.fanClubPost {
                EmbeddedRippleView(ripple: echoed)
                    .padding(.horizontal, 14)
            }
        case .westreemEvent:
            if let event = attachment.vibeEvent {
                RippleEventAttachmentView(event: event)
                    .padding(.horizontal, 14)
            }
        case .photo, .unknown:
            EmptyView()
        }
    }
}

private struct RippleEventAttachmentView: View {
    let event: RippleEventAttachment
    @State private var rsvpStatus: String?
    @State private var goingCount: Int

    init(event: RippleEventAttachment) {
        self.event = event
        _goingCount = State(initialValue: event.goingCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let slug = event.slug {
                    NavigationLink(value: AppRoute.event(slug)) { eventContent }
                        .buttonStyle(.plain)
                } else {
                    eventContent
                }
            }
            if let slug = event.slug {
                EventRsvpButtons(
                    slug: slug,
                    eventStatus: event.status ?? "SCHEDULED",
                    selected: $rsvpStatus,
                    goingCount: $goingCount
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle))
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: C.mediaURL(event.coverURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [C.watch.opacity(0.35), Color.indigo.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .aspectRatio(16 / 9, contentMode: .fill)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        event.status == "LIVE" ? "LIVE NOW" : "EVENT",
                        systemImage: event.status == "LIVE" ? "dot.radiowaves.left.and.right" : "calendar"
                    )
                    .font(.caption2.weight(.black))
                    .foregroundStyle(event.status == "LIVE" ? Color.red : C.watch)
                    Spacer()
                    if event.visibility == "INVITE_ONLY" {
                        Image(systemName: "lock.fill").foregroundStyle(C.textMuted)
                    }
                }
                Text(event.title ?? "Event")
                    .font(.headline)
                    .foregroundStyle(C.text)
                    .lineLimit(2)
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }
                HStack(spacing: 12) {
                    if let startsAt = event.startsAt,
                       let date = startsAt.vibeEventDate {
                        Label(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()), systemImage: "clock")
                    }
                    if goingCount > 0 {
                        Label("\(goingCount) going", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(C.textMuted)
            }
            .padding(14)
        }
    }
}

private struct RipplePhotoCarousel: View {
    let photos: [RippleAttachment]
    @State private var selectedPhoto: RippleAttachment?
    @State private var energyPhoto: RippleAttachment?
    @State private var selectedPhotoID: String?

    init(photos: [RippleAttachment]) {
        self.photos = photos
        _selectedPhotoID = State(initialValue: photos.first?.id ?? "")
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        CachedRemoteImage(
                            url: C.mediaURL(photo.imageURL),
                            targetSize: CGSize(width: proxy.size.width, height: proxy.size.width)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            C.elevated
                        }
                        .frame(width: proxy.size.width, height: proxy.size.width)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(photoTapGesture(photo))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Open photo \(index + 1) of \(photos.count)")
                        .accessibilityHint("Double tap to add Energy")
                        .accessibilityAction(named: "Add Energy") {
                            energyPhoto = photo
                        }
                        .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedPhotoID)
            .ownsHorizontalCarouselGesture()
            .overlay(alignment: .topTrailing) {
                if photos.count > 1 {
                    Text("\(selectedIndex) / \(photos.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .fullScreenCover(item: $selectedPhoto) { selected in
            RipplePhotoViewer(
                photos: photos,
                initialPhotoID: selected.id,
                onClose: { selectedPhoto = nil }
            )
        }
        .sheet(item: $energyPhoto) { photo in
            RipplePhotoEnergySheet(attachmentId: photo.id) { _ in
                energyPhoto = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var selectedIndex: Int {
        (photos.firstIndex { $0.id == selectedPhotoID } ?? 0) + 1
    }

    private func photoTapGesture(
        _ photo: RippleAttachment
    ) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first(_):
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    energyPhoto = photo
                case .second(_):
                    selectedPhoto = photo
                }
            }
    }
}

private struct RipplePhotoViewer: View {
    let photos: [RippleAttachment]
    let onClose: () -> Void
    @State private var selectedPhotoID: String
    @State private var dismissOffset: CGFloat = 0
    @State private var didCrossDismissThreshold = false

    init(photos: [RippleAttachment], initialPhotoID: String, onClose: @escaping () -> Void) {
        self.photos = photos
        self.onClose = onClose
        _selectedPhotoID = State(initialValue: initialPhotoID)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                TabView(selection: $selectedPhotoID) {
                    ForEach(photos) { photo in
                        RipplePhotoViewerPage(photo: photo)
                            .tag(photo.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: dismissOffset)
                .scaleEffect(dismissScale)
                .simultaneousGesture(dragToDismissGesture)

                viewerHeader(topInset: proxy.safeAreaInsets.top)
            }
            .ignoresSafeArea()
        }
    }

    private var selectedIndex: Int {
        (photos.firstIndex { $0.id == selectedPhotoID } ?? 0) + 1
    }

    private var dismissProgress: CGFloat {
        min(max(dismissOffset / 280, 0), 1)
    }

    private var dismissScale: CGFloat {
        1 - dismissProgress * 0.08
    }

    private var backgroundOpacity: Double {
        Double(1 - dismissProgress * 0.55)
    }

    private func viewerHeader(topInset: CGFloat) -> some View {
        HStack {
            if photos.count > 1 {
                Text("\(selectedIndex) / \(photos.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.black.opacity(0.62), in: Capsule())
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close photo viewer")
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset + 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(1 - Double(dismissProgress))
        .zIndex(10)
    }

    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }

                dismissOffset = value.translation.height
                let crossed = dismissOffset >= 110
                if crossed && !didCrossDismissThreshold {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                didCrossDismissThreshold = crossed
            }
            .onEnded { value in
                let isDownward = value.translation.height > 0
                    && abs(value.translation.height) > abs(value.translation.width)
                let shouldDismiss = isDownward
                    && (value.translation.height >= 110 || value.predictedEndTranslation.height >= 220)

                if shouldDismiss {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dismissOffset = max(value.predictedEndTranslation.height, 700)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        onClose()
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        dismissOffset = 0
                    }
                    didCrossDismissThreshold = false
                }
            }
    }
}

private struct RipplePhotoViewerPage: View {
    let photo: RippleAttachment
    @State private var energyCount = 0
    @State private var energyTotal = 0
    @State private var energyTags: [String] = []
    @State private var commentCount: Int
    @State private var showsEnergy = false
    @State private var showsComments = false
    @State private var errorMessage: String?

    init(photo: RippleAttachment) {
        self.photo = photo
        _commentCount = State(initialValue: photo.commentCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            CachedRemoteImage(
                url: C.mediaURL(photo.imageURL),
                targetSize: UIScreen.main.bounds.size
            ) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showsEnergy = true
            }
            .accessibilityAction(named: "Add Energy") {
                showsEnergy = true
            }
            Spacer(minLength: 20)
            if energyCount > 0 {
                SocialEnergyMeter(
                    total: energyTotal,
                    count: energyCount,
                    tags: energyTags
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            HStack(spacing: 28) {
                Button {
                    showsEnergy = true
                } label: {
                    photoAction(
                        icon: "bolt.fill",
                        label: "Add Energy",
                        count: energyCount,
                        active: false
                    )
                }

                Button {
                    showsComments = true
                } label: {
                    photoAction(
                        icon: "bubble.left",
                        label: "Comment",
                        count: commentCount,
                        active: false
                    )
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.black.opacity(0.82))
        }
        .safeAreaPadding(.top, 58)
        .safeAreaPadding(.bottom, 8)
        .task { await loadEnergy() }
        .sheet(isPresented: $showsEnergy) {
            RipplePhotoEnergySheet(attachmentId: photo.id) { aggregate in
                apply(aggregate)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showsComments) {
            StandardCommentsSheet(
                target: .ripplePhoto(photo.id),
                initialCount: commentCount,
                autoFocusComposer: true,
                onClose: { showsComments = false },
                onCountChange: { commentCount = $0 }
            )
        }
        .alert(
            "Photo update failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func photoAction(icon: String, label: String, count: Int, active: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(label)
            if count > 0 {
                Text(count.formatted(.number.notation(.compactName)))
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(active ? C.watch : .white)
        .frame(minHeight: 36)
    }

    private func loadEnergy() async {
        do {
            let response = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).ripplePhotoEnergy(attachmentId: photo.id)
            await MainActor.run { apply(response.aggregate) }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ aggregate: RippleEnergyAggregate) {
        energyCount = max(0, aggregate.count)
        energyTotal = Int(((aggregate.avg ?? 0) * Double(energyCount)).rounded())
        energyTags = aggregate.topTags
    }
}

private struct RipplePhotoEnergySheet: View {
    let attachmentId: String
    let onSaved: (RippleEnergyAggregate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var overall = 0
    @State private var tags = Set<String>()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasExistingEnergy = false
    @State private var confirmationMessage: String?

    var body: some View {
        SocialEnergyForm(
            contentLabel: "photo",
            isUpdate: hasExistingEnergy,
            overall: $overall,
            selectedTags: $tags,
            isSaving: isSaving || isLoading,
            errorMessage: errorMessage,
            confirmationMessage: confirmationMessage,
            onClose: { dismiss() },
            onSubmit: { Task { await save() } },
            onRemove: hasExistingEnergy ? { Task { await remove() } } : nil
        )
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).ripplePhotoEnergy(attachmentId: attachmentId)
            if let current = response.userRating {
                overall = current.overall
                tags = Set(current.tags.map(canonicalEnergyTag))
                hasExistingEnergy = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        do {
            let api = LegacySocialAPIAdapter(transport: APIClient.shared)
            _ = try await api.addEnergy(
                toPhoto: attachmentId,
                overall: overall,
                tags: Array(tags)
            )
            let refreshed = try await api.ripplePhotoEnergy(attachmentId: attachmentId)
            onSaved(refreshed.aggregate)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                confirmationMessage = personalEnergyFeeling(tags: tags, overall: overall)
            }
            try? await Task.sleep(for: .milliseconds(1_200))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    @MainActor
    private func remove() async {
        guard !isSaving, hasExistingEnergy else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let api = LegacySocialAPIAdapter(transport: APIClient.shared)
            try await api.removeEnergy(fromPhoto: attachmentId)
            let refreshed = try await api.ripplePhotoEnergy(attachmentId: attachmentId)
            onSaved(refreshed.aggregate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct RippleLinkAttachment: View {
    let attachment: RippleAttachment
    @EnvironmentObject private var inAppBrowser: InAppBrowserManager

    var body: some View {
        Group {
            if let url = secureExternalURL {
                Button {
                    if C.isTrustedBackendURL(url),
                       let route = AppRoute.route(link: url.absoluteString) {
                        NotificationCenter.default.post(
                            name: .mentionNavigationRequested,
                            object: route
                        )
                    } else {
                        inAppBrowser.open(url)
                    }
                } label: {
                    card
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in the in-app browser")
            } else {
                card
            }
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        HStack(spacing: 10) {
            if let image = attachment.linkImageURL ?? attachment.linkFaviconURL {
                CachedRemoteImage(
                    url: C.mediaURL(image),
                    targetSize: CGSize(width: 84, height: 64)
                ) { loaded in
                    loaded.resizable().scaledToFill()
                } placeholder: {
                    C.elevated
                }
                .frame(width: 84, height: 64)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.linkTitle ?? attachment.linkDomain ?? "Open link")
                    .font(.subheadline.bold())
                    .foregroundStyle(C.textMuted)
                    .lineLimit(1)
                if let description = attachment.linkDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }
                if let domain = attachment.linkDomain {
                    Text(domain.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(C.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var secureExternalURL: URL? {
        guard let value = attachment.externalURL,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
}

private struct RippleVideoAttachmentView: View {
    let video: RippleVideoAttachment
    @Binding var activePreviewVideoId: String?
    let previewManager: FeedPreviewPlayerManager?
    let isAutoplayBlocked: Bool
    let isPreservingPreviewHandoff: Bool
    let onPreviewPaused: (String) -> Void
    let onVideoHandoff: (FeedVideo, CGRect?) -> Void

    @ViewBuilder
    var body: some View {
        if let previewManager {
            HomeVideoCard(
                video: video.feedVideo,
                mediaRoute: video.appRoute,
                sourceRoute: nil,
                activePreviewVideoId: $activePreviewVideoId,
                previewManager: previewManager,
                isAutoplayBlocked: isAutoplayBlocked,
                isPreservingPreviewHandoff: isPreservingPreviewHandoff,
                onPreviewPaused: { onPreviewPaused(video.id) },
                openMediaAction: {
                    NotificationCenter.default.post(
                        name: .mentionNavigationRequested,
                        object: video.appRoute
                    )
                },
                replaceMediaAction: video.videoURL == nil
                    ? nil
                    : { frame in onVideoHandoff(video.feedVideo, frame) }
            )
        } else {
            NavigationLink(value: video.appRoute) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    url: C.mediaURL(video.thumbnailURL),
                    targetSize: CGSize(width: UIScreen.main.bounds.width, height: 240)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    C.elevated
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(C.mediaAspectRatio(forContentType: video.type), contentMode: .fit)
                .clipped()

                Circle()
                    .fill(.black.opacity(0.66))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "play.fill").foregroundStyle(.white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let duration = video.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(video.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.linearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct RippleCollectionAttachmentView: View {
    let collection: RippleCollectionAttachment

    var body: some View {
        NavigationLink(value: AppRoute.collection(collection.id)) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(C.watch)
                    .frame(width: 48, height: 48)
                    .background(C.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title).font(.subheadline.bold()).foregroundStyle(C.text)
                    if let description = collection.description {
                        Text(description).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(C.textTertiary)
            }
            .padding(12)
            .background(C.elevated, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct RippleClipAttachmentView: View {
    let clip: RippleClippingAttachment
    @State private var showsPlayer = false

    private var source: RippleVideoAttachment? {
        clip.video ?? clip.episode.map {
            RippleVideoAttachment(
                id: $0.id,
                title: $0.title,
                thumbnailURL: $0.thumbnailUrl,
                videoURL: $0.videoUrl,
                duration: $0.duration
            )
        }
    }

    var body: some View {
        Button {
            guard playbackRange != nil, clip.videoId != nil || clip.episodeId != nil else { return }
            showsPlayer = true
        } label: {
        VStack(alignment: .leading, spacing: 9) {
            if let source {
                ZStack {
                    CachedRemoteImage(
                        url: C.mediaURL(source.thumbnailURL),
                        targetSize: CGSize(width: 480, height: 270)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        C.elevated
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            if let markIn = clip.markIn, let markOut = clip.markOut, markOut > markIn {
                ClipRangeBar(markIn: markIn, markOut: markOut, duration: source?.duration)
            }
            if let caption = clip.caption, !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(C.textMuted)
            }
        }
        .padding(10)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showsPlayer) {
            NavigationStack {
                Group {
                    if let videoId = clip.videoId, let playbackRange {
                        VideoWatchView(videoId: videoId, initialClipRange: playbackRange)
                    } else if let episodeId = clip.episodeId, let playbackRange {
                        EpisodeWatchView(episodeId: episodeId, initialClipRange: playbackRange)
                    } else {
                        ContentUnavailableView("Clip unavailable", systemImage: "play.slash")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showsPlayer = false }
                    }
                }
            }
        }
    }

    private var playbackRange: ClipPlaybackRange? {
        guard let markIn = clip.markIn,
              let markOut = clip.markOut,
              markIn >= 0,
              markOut > markIn else { return nil }
        return ClipPlaybackRange(markIn: markIn, markOut: markOut)
    }
}

private struct ClipRangeBar: View {
    let markIn: Double
    let markOut: Double
    let duration: Double?

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let total = max(duration ?? markOut, markOut, 1)
                let start = min(max(markIn / total, 0), 1)
                let end = min(max(markOut / total, start), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(C.border)
                    Capsule()
                        .fill(C.watch)
                        .frame(width: max(4, proxy.size.width * CGFloat(end - start)))
                        .offset(x: proxy.size.width * CGFloat(start))
                }
            }
            .frame(height: 5)
            HStack {
                Text(formatDuration(markIn))
                Spacer()
                Text(formatDuration(markOut))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(C.textMuted)
        }
    }
}

private struct EmbeddedRippleView: View {
    let ripple: EmbeddedRipple

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SocialIdentityAvatar(
                    image: ripple.author.image,
                    name: ripple.author.name ?? ripple.author.handle,
                    size: 30
                )
                Text(ripple.author.name ?? ripple.author.handle.map { "@\($0)" } ?? "Westreem user")
                    .font(.caption.bold())
                Spacer()
                if ripple.energyCount > 0 {
                    Label("\(ripple.energyCount)", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                }
            }
            if let body = ripple.body, !body.isEmpty {
                MentionText(plain: body, html: nil, font: .subheadline, color: C.text)
                    .lineLimit(5)
            }
        }
        .padding(12)
        .background(C.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.border))
    }
}

private struct RipplePollCard: View {
    let poll: RipplePoll
    let allowsVoting: Bool
    let isSaving: Bool
    let onVote: ([String]) -> Void
    @State private var selections: Set<String>

    init(
        poll: RipplePoll,
        allowsVoting: Bool,
        isSaving: Bool,
        onVote: @escaping ([String]) -> Void
    ) {
        self.poll = poll
        self.allowsVoting = allowsVoting
        self.isSaving = isSaving
        self.onVote = onVote
        let selected = Set(poll.votes.map(\.optionId))
        _selections = State(initialValue: selected)
    }

    private var showResults: Bool {
        !poll.votes.isEmpty || isClosed || poll.resultsVisibility.uppercased() == "ALWAYS"
    }

    private var isClosed: Bool {
        if poll.closedAt != nil { return true }
        guard let closesAt = poll.closesAt,
              let closeDate = ISO8601DateFormatter().date(from: closesAt) else { return false }
        return closeDate <= Date()
    }

    private var statusText: String {
        if isClosed { return "Poll closed" }
        if isSaving { return "Saving…" }
        if !poll.votes.isEmpty { return "Vote saved" }
        return allowsVoting ? "Tap to vote" : "Voting unavailable"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(poll.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.text)
                    .multilineTextAlignment(.center)

                Text(
                    poll.allowsMultiple
                        ? "Select up to \(poll.maxSelections) answers"
                        : "Select one answer"
                )
                .font(.system(size: 11))
                .foregroundStyle(C.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(poll.options) { option in
                    pollOption(option)
                }
            }

            HStack {
                if showResults {
                    Text(
                        poll.totalVoters == 1
                            ? "1 vote"
                            : "\(poll.totalVoters) votes"
                    )
                }
                Spacer()
                Text(statusText)
            }
            .font(.system(size: 10))
            .foregroundStyle(C.textMuted)
            .padding(.top, 9)
        }
        .padding(12)
        .background(.black.opacity(0.65))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: poll.votes.map(\.optionId)) { _, optionIDs in
            selections = Set(optionIDs)
        }
    }

    private func pollOption(_ option: RipplePollOption) -> some View {
        let selected = selections.contains(option.id)
        let fraction = poll.totalVoters > 0
            ? min(max(Double(option.voteCount) / Double(poll.totalVoters), 0), 1)
            : 0

        return Button {
            select(option.id)
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.15))

                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? C.watch : .white.opacity(0.20))
                        .frame(
                            width: proxy.size.width
                                * CGFloat(showResults ? fraction : 0)
                        )
                        .opacity(showResults ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.55), value: showResults)
                .animation(.easeOut(duration: 0.55), value: fraction)
                .animation(.easeInOut(duration: 0.22), value: selected)

                HStack(spacing: 12) {
                    Text(option.label)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if showResults {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .opacity(0.75)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected && showResults ? C.bg : C.text)
                .padding(.horizontal, 12)
                .animation(.easeInOut(duration: 0.22), value: selected)
            }
            .frame(height: 40)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!allowsVoting || isClosed)
        .opacity(allowsVoting || isClosed ? 1 : 0.82)
        .accessibilityValue(showResults ? "\(Int((fraction * 100).rounded())) percent" : "")
    }

    private func select(_ id: String) {
        guard allowsVoting, !isClosed else { return }
        var updated = selections

        if poll.allowsMultiple {
            if updated.contains(id) {
                updated.remove(id)
            } else if updated.count < poll.maxSelections {
                updated.insert(id)
            } else {
                return
            }
        } else {
            updated = [id]
        }

        selections = updated
        onVote(Array(updated).sorted())
    }
}

private struct RippleEnergySheet: View {
    @ObservedObject var controller: RippleEngagementController
    @Environment(\.dismiss) private var dismiss
    @State private var overall = 0
    @State private var tags: Set<String> = []
    @State private var confirmationMessage: String?

    var body: some View {
        SocialEnergyForm(
            contentLabel: "Ripple",
            isUpdate: controller.currentEnergy != nil,
            overall: $overall,
            selectedTags: $tags,
            isSaving: controller.isBusy,
            errorMessage: controller.errorMessage,
            confirmationMessage: confirmationMessage,
            onClose: { dismiss() },
            onSubmit: {
                Task {
                    if await controller.submitEnergy(overall: overall, tags: Array(tags)) {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                            confirmationMessage = personalEnergyFeeling(tags: tags, overall: overall)
                        }
                        try? await Task.sleep(for: .milliseconds(1_200))
                        dismiss()
                    }
                }
            },
            onRemove: controller.currentEnergy == nil ? nil : {
                Task {
                    if await controller.removeEnergy() {
                        dismiss()
                    }
                }
            }
        )
        .onAppear {
            if let current = controller.currentEnergy {
                overall = current.overall
                tags = Set(current.tags.map(canonicalEnergyTag))
            }
        }
    }
}

enum ContentEnergyKind {
    case video
    case episode
    case flash

    var path: String {
        switch self {
        case .video: "videos"
        case .episode: "episodes"
        case .flash: "stories"
        }
    }

    var label: String {
        switch self {
        case .video: "video"
        case .episode: "episode"
        case .flash: "Flash"
        }
    }
}

struct ContentEnergySheet: View {
    let kind: ContentEnergyKind
    let contentID: String
    var onSaved: ((ContentEnergyAggregate) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var overall = 0
    @State private var tags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasExistingEnergy = false
    @State private var confirmationMessage: String?

    var body: some View {
        SocialEnergyForm(
            contentLabel: kind.label,
            isUpdate: hasExistingEnergy,
            overall: $overall,
            selectedTags: $tags,
            isSaving: isSaving,
            errorMessage: errorMessage,
            confirmationMessage: confirmationMessage,
            onClose: { dismiss() },
            onSubmit: { Task { await save() } },
            onRemove: hasExistingEnergy ? { Task { await remove() } } : nil
        )
        .task { await loadCurrentEnergy() }
    }

    @MainActor
    private func loadCurrentEnergy() async {
        guard !isSaving else { return }
        if let response = try? await APIClient.shared.fetchContentEnergy(
            contentPath: kind.path,
            id: contentID
        ), let current = response.userRating {
            overall = current.overall
            tags = Set(current.tags.map(canonicalEnergyTag))
            hasExistingEnergy = true
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await APIClient.shared.submitContentEnergy(
                contentPath: kind.path,
                id: contentID,
                overall: overall,
                tags: Array(tags)
            )
            let updated = try await APIClient.shared.fetchContentEnergy(
                contentPath: kind.path,
                id: contentID
            )
            onSaved?(updated.aggregate)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                confirmationMessage = personalEnergyFeeling(tags: tags, overall: overall)
            }
            try? await Task.sleep(for: .milliseconds(1_200))
            dismiss()
        } catch {
            errorMessage = "Energy could not be saved. Please try again."
        }
    }

    @MainActor
    private func remove() async {
        guard !isSaving, hasExistingEnergy else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await APIClient.shared.removeContentEnergy(
                contentPath: kind.path,
                id: contentID
            )
            let updated = try await APIClient.shared.fetchContentEnergy(
                contentPath: kind.path,
                id: contentID
            )
            onSaved?(updated.aggregate)
            dismiss()
        } catch {
            errorMessage = "Energy could not be removed. Please try again."
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: proposal.width ?? x, height: y + rowHeight), points)
    }
}

private struct NativeShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SocialEnergyForm: View {
    let contentLabel: String
    let isUpdate: Bool
    @Binding var overall: Int
    @Binding var selectedTags: Set<String>
    let isSaving: Bool
    let errorMessage: String?
    var confirmationMessage: String? = nil
    let onClose: () -> Void
    let onSubmit: () -> Void
    var onRemove: (() -> Void)? = nil
    @State private var confirmsRemoval = false

    private let choices = ["Hits", "Inspired", "Real", "Deep", "Chill", "Clutch"]
    private let signalColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isUpdate ? "Your signal" : "Add Energy")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.2)
                        .textCase(.uppercase)
                        .foregroundStyle(C.watch)
                    Text("What energy is this giving?")
                        .font(.title3.bold())
                        .foregroundStyle(C.text)
                    Text("Tap the level, then choose every signal that fits this \(contentLabel).")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(C.textMuted)
                        .frame(width: 32, height: 32)
                        .background(C.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            if confirmationMessage == nil {
                SocialEnergyLevelPicker(value: $overall)
                    .padding(14)
                    .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(C.borderSubtle, lineWidth: 1)
                    }

                HStack {
                    Text("Add a signal")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(overall > 0 ? "CHOOSE ANY" : "SELECT INTENSITY FIRST")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(C.textTertiary)
                }

                LazyVGrid(columns: signalColumns, spacing: 8) {
                    ForEach(choices, id: \.self) { choice in
                        let selected = selectedTags.contains(choice)
                        Button {
                            if selected { selectedTags.remove(choice) }
                            else { selectedTags.insert(choice) }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: energySymbol(choice))
                                    .font(.system(size: 20, weight: .semibold))
                                Text(energyLabel(choice))
                                    .font(.system(size: 12, weight: .bold))
                            }
                                .foregroundStyle(selected ? C.bg : C.textMuted)
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .background(
                                    selected ? AnyShapeStyle(energyGradient) : AnyShapeStyle(Color.white.opacity(0.035)),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(selected ? Color.white.opacity(0.30) : C.borderSubtle, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(overall < 1)
                        .opacity(overall < 1 ? 0.35 : 1)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint(
                            overall < 1
                                ? "Select an Energy intensity before choosing a signal."
                                : "Adds or removes this Energy signal."
                        )
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                HStack(spacing: 8) {
                    Button(action: onSubmit) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(C.bg)
                            }
                            Text(isSaving ? "Sending…" : isUpdate ? "Update Energy" : "Send Energy")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(C.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(energyGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || overall < 1)
                    .opacity(isSaving || overall < 1 ? 0.45 : 1)

                    if isUpdate, onRemove != nil {
                        Button(role: .destructive) {
                            confirmsRemoval = true
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "bolt.slash")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Remove")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(.red.opacity(0.92))
                            .frame(width: 74, height: 48)
                            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.red.opacity(0.20), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                        .accessibilityLabel("Remove Energy")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background {
            ZStack {
                Color(hex: "#0E0E16")
                RadialGradient(
                    colors: [Color(hex: "#A780D7").opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 260
                )
                RadialGradient(
                    colors: [Color(hex: "#6AE383").opacity(0.10), .clear],
                    center: UnitPoint(x: 0.08, y: 0.22),
                    startRadius: 0,
                    endRadius: 220
                )
            }
            .ignoresSafeArea()
        }
        .overlay {
            if let confirmationMessage {
                ZStack {
                    Color(hex: "#0E0E16").opacity(0.96)
                    VStack(spacing: 12) {
                        Image(systemName: energySymbol(selectedTags.sorted().first ?? "CLUTCH"))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(C.bg)
                            .frame(width: 64, height: 64)
                            .background(energyGradient, in: Circle())
                            .shadow(color: Color(hex: "#A780D7").opacity(0.42), radius: 22)
                            .symbolEffect(.bounce, value: confirmationMessage)
                        Text("ENERGY SENT")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(2.2)
                            .foregroundStyle(C.textMuted)
                        Text("This made you feel")
                            .font(.title2.bold())
                            .foregroundStyle(C.text)
                        Text(confirmationMessage)
                            .font(.title3.bold())
                            .foregroundStyle(C.watch)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .presentationBackground(Color(hex: "#0E0E16"))
        .foregroundStyle(C.text)
        .confirmationDialog(
            "Remove your Energy?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Energy", role: .destructive) {
                onRemove?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Energy and selected keywords will be removed from this \(contentLabel).")
        }
    }

    private func energyLevelDescription(_ level: Int) -> String {
        ["", "Low key", "Warm", "Charged", "High energy", "Electric"][min(max(level, 0), 5)]
    }
}

private let energyGradient = LinearGradient(
    colors: [
        Color(hex: "#6AE383"),
        Color(hex: "#B7E875"),
        Color(hex: "#F2D36B"),
        Color(hex: "#E8A15F"),
        Color(hex: "#A780D7"),
        Color(hex: "#5967C9")
    ],
    startPoint: .leading,
    endPoint: .trailing
)

private func personalEnergyFeeling(tags: Set<String>, overall: Int) -> String {
    let feelings = tags
        .sorted()
        .map(energyLabel)
    if feelings.isEmpty {
        return ["", "Low key", "Warm", "Charged", "High energy", "Electric"][min(max(overall, 0), 5)]
    }
    return feelings.joined(separator: " · ")
}

struct SocialEnergyMeter: View {
    let total: Int
    let count: Int
    let tags: [String]

    private var average: Double {
        count > 0 ? min(max(Double(total) / Double(count), 0), 5) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(String(format: "%.1f", average))
                    .font(.caption.bold().monospacedDigit())
                Text(count == 1 ? "1 Energy" : "\(count) Energy")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                Spacer()
                ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                    Text(energyLabel(tag))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(C.borderSubtle)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "#6AE383"),
                                    Color(hex: "#B7E875"),
                                    Color(hex: "#F2D36B"),
                                    Color(hex: "#E8A15F"),
                                    Color(hex: "#A780D7"),
                                    Color(hex: "#5967C9")
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * CGFloat(average / 5))
                }
            }
            .frame(height: 3)
        }
    }
}

struct SocialEnergyLevelPicker: View {
    @Binding var value: Int
    @State private var lastHapticValue: Int?

    private let colors = [
        Color(hex: "#6AE383"),
        Color(hex: "#B7E875"),
        Color(hex: "#F2D36B"),
        Color(hex: "#E8A15F"),
        Color(hex: "#A780D7"),
        Color(hex: "#5967C9")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intensity")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                        .textCase(.uppercase)
                        .foregroundStyle(C.textMuted)
                    Text(value > 0 ? energyIntensityLabel(value) : "Pick your level")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(C.text)
                }
                Spacer()
                if value > 0 {
                    Text("\(value)/5")
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(C.text.opacity(0.50))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 10)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(value) / 5)
                        .frame(height: 10)
                        .shadow(color: Color(hex: "#5967C9").opacity(0.26), radius: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .overlay { Circle().stroke(C.bg.opacity(0.35), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                        .offset(x: max(0, min(proxy.size.width - 16, proxy.size.width * CGFloat(value - 1) / 4)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { gesture in
                            updateValue(at: gesture.location.x, width: proxy.size.width)
                        }
                        .onEnded { _ in
                            lastHapticValue = nil
                        }
                )
            }
            .frame(height: 30)
            .accessibilityElement()
            .accessibilityLabel("Energy")
            .accessibilityValue("\(value) of 5")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = min(5, value + 1)
                case .decrement: value = max(1, value - 1)
                @unknown default: break
                }
            }

            HStack {
                Text("Low")
                Spacer()
                Text("Electric")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(C.textTertiary)

            GeometryReader { proxy in
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { level in
                        Button {
                            selectLevel(level)
                        } label: {
                            Text("\(level)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(level == value ? C.text : C.textMuted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(
                                    level == value ? Color.white.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Energy \(level)")
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { gesture in
                            updateValue(at: gesture.location.x, width: proxy.size.width)
                        }
                        .onEnded { _ in
                            lastHapticValue = nil
                        }
                )
            }
            .frame(height: 28)
        }
    }

    private func updateValue(at x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let progress = min(max(x / width, 0), 1)
        let nextValue = min(max(Int((progress * 4).rounded()) + 1, 1), 5)
        guard nextValue != value else { return }
        value = nextValue
        if lastHapticValue != nextValue {
            UISelectionFeedbackGenerator().selectionChanged()
            lastHapticValue = nextValue
        }
    }

    private func selectLevel(_ level: Int) {
        value = min(max(level, 1), 5)
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private func energyIntensityLabel(_ value: Int) -> String {
    ["", "Low key", "Warm", "Charged", "High energy", "Electric"][min(max(value, 0), 5)]
}

private func energyLabel(_ value: String) -> String {
    switch value.uppercased() {
    case "HITS": "Hits"
    case "INSPIRED": "Inspired"
    case "REAL": "Real"
    case "DEEP": "Deep"
    case "CHILL": "Chill"
    case "CLUTCH": "Clutch"
    default: value.capitalized
    }
}

private func canonicalEnergyTag(_ value: String) -> String {
    energyLabel(value)
}

private func energySymbol(_ value: String) -> String {
    switch value.uppercased() {
    case "HITS": "waveform.path"
    case "INSPIRED": "star.fill"
    case "REAL": "lightbulb.fill"
    case "DEEP": "brain.head.profile"
    case "CHILL": "face.smiling"
    case "CLUTCH": "bolt.fill"
    default: "sparkles"
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let remaining = value % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
        : String(format: "%d:%02d", minutes, remaining)
}

extension RippleVideoAttachment {
    var appRoute: AppRoute {
        AppRoute.media(id: id, type: type)
    }

    var feedVideo: FeedVideo {
        FeedVideo(
            id: id,
            title: title,
            thumbnailUrl: thumbnailURL,
            videoUrl: videoURL,
            duration: duration,
            aspectRatio: width.flatMap { width in
                height.flatMap { height in height > 0 ? Double(width) / Double(height) : nil }
            },
            width: width,
            height: height,
            views: views ?? 0,
            type: type,
            publishedAt: nil,
            createdAt: "",
            channel: nil,
            show: nil
        )
    }

    init(
        id: String,
        title: String,
        thumbnailURL: String?,
        videoURL: String?,
        duration: Double?
    ) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.thumbnailFocus = nil
        self.videoURL = videoURL
        self.duration = duration
        self.type = nil
        self.width = nil
        self.height = nil
        self.views = nil
    }
}
