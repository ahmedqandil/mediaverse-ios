import SwiftUI
import UIKit

struct RippleCardActions {
    var addEnergy: (() -> Void)?
    var comment: (() -> Void)?
    var echo: (() -> Void)?
    var share: (() -> Void)?
    var openAuthor: (() -> Void)?
    var openVibe: (() -> Void)?
    var togglePin: (() -> Void)?
    var isPinned = false
    var edit: (() -> Void)?
    var delete: (() -> Void)?
    var report: (() -> Void)?

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
                    .padding(.top, 10)
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
                    onCountChange: { displayedCommentCount = $0 }
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
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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
            .presentationDetents([.large])
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
                            actions.isPinned ? "Unpin from Atmo" : "Pin to Atmo",
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
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(count > 0 ? "\(title) · \(count)" : title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                    Toggle("Spoiler", isOn: $isSpoiler)
                    Toggle("Disable comments", isOn: $commentsDisabled)
                }
                Section {
                    Text("Existing photos, media, polls, and Echo attachments are preserved and cannot be changed here.")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
            }
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

private struct RippleReportSheet: View {
    let postId: String
    let vibeSlug: String
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    TextField("Reason for reporting", text: $reason)
                    TextField("Optional details", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Text("The Vibe’s moderation team will review this report.")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
            }
            .navigationTitle("Report Ripple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(
                            isSubmitting
                            || reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 3
                            || reason.count > 100
                            || details.count > 2_000
                        )
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

    @MainActor
    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        do {
            _ = try await api.reportRipple(
                postId: postId,
                vibeSlug: vibeSlug,
                reason: reason,
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
                RipplePhotoGrid(photos: photos)
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
        case .photo, .unknown:
            EmptyView()
        }
    }
}

private struct RipplePhotoGrid: View {
    let photos: [RippleAttachment]
    @State private var selectedPhoto: RippleAttachment?
    @State private var energyPhoto: RippleAttachment?

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let columns = photos.count == 1 ? 1 : 2
            let width = (proxy.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns),
                spacing: spacing
            ) {
                ForEach(Array(photos.prefix(4).enumerated()), id: \.element.id) { index, photo in
                    CachedRemoteImage(
                        url: C.mediaURL(photo.imageURL),
                        targetSize: CGSize(width: width, height: photos.count == 1 ? width : width * 0.9)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        C.elevated
                    }
                    .frame(width: width, height: photos.count == 1 ? width : width * 0.9)
                    .clipped()
                    .overlay {
                        if index == 3, photos.count > 4 {
                            Color.black.opacity(0.55)
                            Text("+\(photos.count - 3)")
                                .font(.title.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(photoTapGesture(photo))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open photo \(index + 1) of \(photos.count)")
                    .accessibilityHint("Double tap to open")
                    .accessibilityAction(named: "Add Energy") {
                        energyPhoto = photo
                    }
                }
            }
        }
        .aspectRatio(photos.count == 1 ? 1 : (photos.count == 2 ? 1.7 : 1.1), contentMode: .fit)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
    @State private var overall = 3
    @State private var tags = Set<String>()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasExistingEnergy = false

    var body: some View {
        SocialEnergyForm(
            contentLabel: "photo",
            isUpdate: hasExistingEnergy,
            overall: $overall,
            selectedTags: $tags,
            isSaving: isSaving || isLoading,
            errorMessage: errorMessage,
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
                tags = Set(current.tags)
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
                    .foregroundStyle(C.text)
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

                if showResults {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? C.watch : .white.opacity(0.20))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                }

                HStack(spacing: 12) {
                    Text(option.label)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if showResults {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .opacity(0.75)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected && showResults ? C.bg : C.text)
                .padding(.horizontal, 12)
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
    @State private var overall = 3
    @State private var tags: Set<String> = []

    var body: some View {
        SocialEnergyForm(
            contentLabel: "Ripple",
            isUpdate: controller.currentEnergy != nil,
            overall: $overall,
            selectedTags: $tags,
            isSaving: controller.isBusy,
            errorMessage: controller.errorMessage,
            onClose: { dismiss() },
            onSubmit: {
                Task {
                    if await controller.submitEnergy(overall: overall, tags: Array(tags)) {
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
                tags = Set(current.tags)
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
    @State private var overall = 3
    @State private var tags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasExistingEnergy = false

    var body: some View {
        SocialEnergyForm(
            contentLabel: kind.label,
            isUpdate: hasExistingEnergy,
            overall: $overall,
            selectedTags: $tags,
            isSaving: isSaving,
            errorMessage: errorMessage,
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
            tags = Set(current.tags)
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
    let onClose: () -> Void
    let onSubmit: () -> Void
    var onRemove: (() -> Void)? = nil
    @State private var confirmsRemoval = false

    private let choices = ["HITS", "INSPIRED", "REAL", "DEEP", "CHILL", "CLUTCH"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(isUpdate ? "Update your Energy" : "Add Energy to this \(contentLabel)")
                    .font(.headline)
                    .foregroundStyle(C.text)
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

            SocialEnergyLevelPicker(value: $overall)
                .padding(14)
                .background(C.elevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(C.borderSubtle, lineWidth: 1)
                }

            Text(energyLevelDescription(overall))
                .font(.caption)
                .foregroundStyle(C.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Energy level \(overall), \(energyLevelDescription(overall))")

            FlowLayout(spacing: 7) {
                ForEach(choices, id: \.self) { choice in
                    let selected = selectedTags.contains(choice)
                    Button {
                        if selected { selectedTags.remove(choice) }
                        else { selectedTags.insert(choice) }
                    } label: {
                        Label(energyLabel(choice), systemImage: energySymbol(choice))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? C.bg : C.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selected ? C.watch : Color.clear, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(selected ? Color.clear : C.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button(action: onSubmit) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(C.bg)
                    }
                    Text(isSaving ? "Saving…" : isUpdate ? "Update Energy" : "Add Energy")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(C.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(C.watch, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSaving || overall < 1)
            .opacity(isSaving || overall < 1 ? 0.45 : 1)

            if isUpdate, onRemove != nil {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Remove Energy", systemImage: "bolt.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background(C.bg.ignoresSafeArea())
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
        ["", "Terrible", "Poor", "Okay", "Good", "Excellent"][min(max(level, 1), 5)]
    }
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
                    Label(energyLabel(tag), systemImage: energySymbol(tag))
                        .labelStyle(.iconOnly)
                        .foregroundStyle(C.textMuted)
                        .accessibilityLabel(energyLabel(tag))
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
            .frame(height: 7)
        }
    }
}

struct SocialEnergyLevelPicker: View {
    @Binding var value: Int

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
                Text("Vibe Meter")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(C.textMuted)
                Spacer()
                Text(String(format: "%.1f", Double(value)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(C.text.opacity(0.72))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(value) / 5)
                        .shadow(color: Color(hex: "#5967C9").opacity(0.32), radius: 7)
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .overlay { Circle().stroke(C.bg.opacity(0.35), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                        .offset(x: max(0, min(proxy.size.width - 18, proxy.size.width * CGFloat(value - 1) / 4)))
                    Slider(
                        value: Binding(
                            get: { Double(value) },
                            set: { value = Int($0.rounded()) }
                        ),
                        in: 1...5,
                        step: 1
                    )
                    .opacity(0.015)
                }
            }
            .frame(height: 18)
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

            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        value = level
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
        }
    }
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
