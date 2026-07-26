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
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var engagement: RippleEngagementController
    @State private var showsEnergy = false
    @State private var showsShare = false
    @State private var showsComments = false
    @State private var showsEcho = false
    @State private var showsEdit = false
    @State private var showsReport = false
    @State private var confirmsDelete = false
    @State private var isDeleted = false
    @State private var editedBody: String?
    @State private var editedSpoiler: Bool?
    @State private var editedCommentsDisabled: Bool?

    init(
        ripple: Ripple,
        actions: RippleCardActions = .readOnly,
        allowsEngagement: Bool = false
    ) {
        self.ripple = ripple
        self.actions = actions
        self.allowsEngagement = allowsEngagement
        _engagement = StateObject(wrappedValue: RippleEngagementController(ripple: ripple))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)

            if let body = (editedBody ?? ripple.body)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                MentionText(
                    plain: body,
                    html: nil,
                    font: bodyFont(hasAttachments: !ripple.attachments.isEmpty || ripple.poll != nil),
                    color: C.text
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            if let poll = engagement.poll {
                RipplePollCard(
                    poll: poll,
                    allowsVoting: allowsEngagement && !engagement.isBusy
                ) { optionIds in
                    Task { await engagement.vote(optionIds: optionIds) }
                }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            if !ripple.attachments.isEmpty {
                RippleAttachmentsView(attachments: ripple.attachments)
                    .padding(.top, 12)
            }

            if engagement.energyCount > 0 {
                SocialEnergyMeter(
                    total: engagement.energyTotal,
                    count: engagement.energyCount,
                    tags: engagement.energyTags
                )
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }

            actionBar
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface)
        .overlay {
            RoundedRectangle(cornerRadius: C.cardRadius)
                .stroke(C.borderSubtle, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
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
        .sheet(isPresented: $showsComments) {
            StandardCommentsSheet(
                target: .ripple(ripple.id),
                initialCount: ripple.commentCount,
                autoFocusComposer: true,
                onClose: { showsComments = false }
            )
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
                    size: 40
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
                count: ripple.commentCount,
                handler: actions.comment ?? (
                    allowsEngagement && !(editedCommentsDisabled ?? ripple.commentsDisabled)
                        ? { showsComments = true }
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
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(count > 0 ? "\(title) · \(count)" : title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(handler == nil ? C.textTertiary : C.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
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
                RippleVideoAttachmentView(video: video)
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
                    Button {
                        selectedPhoto = photo
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open photo \(index + 1) of \(photos.count)")
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
    }
}

private struct RipplePhotoViewer: View {
    let photos: [RippleAttachment]
    let onClose: () -> Void
    @State private var selectedPhotoID: String

    init(photos: [RippleAttachment], initialPhotoID: String, onClose: @escaping () -> Void) {
        self.photos = photos
        self.onClose = onClose
        _selectedPhotoID = State(initialValue: initialPhotoID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedPhotoID) {
                ForEach(photos) { photo in
                    RipplePhotoViewerPage(photo: photo)
                        .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close photo viewer")
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
            Spacer(minLength: 60)
            CachedRemoteImage(
                url: C.mediaURL(photo.imageURL),
                targetSize: UIScreen.main.bounds.size
            ) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var existing: RippleEnergySelection?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let choices = ["HITS", "INSPIRED", "REAL", "DEEP", "CHILL", "CLUTCH"]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().tint(C.watch)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("How much Energy?").font(.headline)
                        HStack {
                            ForEach(1...5, id: \.self) { value in
                                Button {
                                    overall = value
                                } label: {
                                    Text("\(value)")
                                        .font(.headline)
                                        .foregroundStyle(value == overall ? C.bg : C.text)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 42)
                                        .background(
                                            value == overall ? C.watch : C.elevated,
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("What kind?").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(choices, id: \.self) { choice in
                                Button {
                                    if tags.contains(choice) { tags.remove(choice) }
                                    else { tags.insert(choice) }
                                } label: {
                                    Label(energyLabel(choice), systemImage: energySymbol(choice))
                                        .font(.caption.bold())
                                        .foregroundStyle(tags.contains(choice) ? C.bg : C.text)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(tags.contains(choice) ? C.watch : C.elevated, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if existing != nil {
                            Button("Remove my Energy", role: .destructive) {
                                Task { await remove() }
                            }
                            .disabled(isSaving)
                        }
                        Spacer()
                    }
                    .padding(C.pagePad)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.bg.ignoresSafeArea())
            .foregroundStyle(C.text)
            .navigationTitle("Add Energy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isLoading || isSaving)
                }
            }
            .task { await load() }
            .alert(
                "Energy update failed",
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
    private func load() async {
        do {
            let response = try await LegacySocialAPIAdapter(
                transport: APIClient.shared
            ).ripplePhotoEnergy(attachmentId: attachmentId)
            existing = response.userRating
            if let rating = response.userRating {
                overall = rating.overall
                tags = Set(rating.tags)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
        guard !isSaving else { return }
        isSaving = true
        do {
            let api = LegacySocialAPIAdapter(transport: APIClient.shared)
            try await api.removeEnergy(fromPhoto: attachmentId)
            let refreshed = try await api.ripplePhotoEnergy(attachmentId: attachmentId)
            onSaved(refreshed.aggregate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct RippleLinkAttachment: View {
    let attachment: RippleAttachment

    var body: some View {
        Group {
            if let url = secureExternalURL {
                Link(destination: url) { card }
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

    var body: some View {
        NavigationLink(value: AppRoute.media(id: video.id, type: video.type)) {
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
    let onVote: ([String]) -> Void
    @State private var selections: Set<String>

    init(
        poll: RipplePoll,
        allowsVoting: Bool,
        onVote: @escaping ([String]) -> Void
    ) {
        self.poll = poll
        self.allowsVoting = allowsVoting
        self.onVote = onVote
        _selections = State(initialValue: Set(poll.votes.map(\.optionId)))
    }

    private var totalVotes: Int { poll.options.reduce(0) { $0 + $1.voteCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(poll.question).font(.headline).foregroundStyle(C.text)
                Spacer()
                Image(systemName: "chart.bar.fill").foregroundStyle(C.watch)
            }
            ForEach(poll.options) { option in
                let fraction = totalVotes > 0 ? Double(option.voteCount) / Double(totalVotes) : 0
                Button {
                    select(option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: selections.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selections.contains(option.id) ? C.watch : C.textTertiary)
                            Text(option.label).font(.subheadline)
                            Spacer()
                            Text("\(Int((fraction * 100).rounded()))%").font(.caption.bold())
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(C.border)
                                Capsule()
                                    .fill(C.watch)
                                    .frame(width: proxy.size.width * CGFloat(fraction))
                            }
                        }
                        .frame(height: 7)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!allowsVoting)
            }
            if poll.allowsMultiple, allowsVoting {
                Button("Submit vote") {
                    onVote(Array(selections).sorted())
                }
                .font(.caption.bold())
                .foregroundStyle(C.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(C.watch, in: Capsule())
                .disabled(selections.isEmpty || selections.count > poll.maxSelections)
            }
            Text(totalVotes == 1 ? "1 vote" : "\(totalVotes) votes")
                .font(.caption)
                .foregroundStyle(C.textMuted)
        }
        .padding(12)
        .background(C.elevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func select(_ id: String) {
        guard allowsVoting else { return }
        if poll.allowsMultiple {
            if selections.contains(id) {
                selections.remove(id)
            } else if selections.count < poll.maxSelections {
                selections.insert(id)
            }
        } else {
            selections = [id]
            onVote([id])
        }
    }
}

private struct RippleEnergySheet: View {
    @ObservedObject var controller: RippleEngagementController
    @Environment(\.dismiss) private var dismiss
    @State private var overall = 3
    @State private var tags: Set<String> = []

    private let choices = ["HITS", "INSPIRED", "REAL", "DEEP", "CHILL", "CLUTCH"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How much Energy?").font(.headline)
                    HStack {
                        ForEach(1...5, id: \.self) { value in
                            Button {
                                overall = value
                            } label: {
                                Text("\(value)")
                                    .font(.headline)
                                    .foregroundStyle(value == overall ? C.bg : C.text)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(value == overall ? C.watch : C.elevated, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What kind?").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(choices, id: \.self) { choice in
                            Button {
                                if tags.contains(choice) { tags.remove(choice) }
                                else { tags.insert(choice) }
                            } label: {
                                Label(energyLabel(choice), systemImage: energySymbol(choice))
                                    .font(.caption.bold())
                                    .foregroundStyle(tags.contains(choice) ? C.bg : C.text)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(tags.contains(choice) ? C.watch : C.elevated, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()
            }
            .padding(C.pagePad)
            .background(C.bg.ignoresSafeArea())
            .foregroundStyle(C.text)
            .navigationTitle("Add Energy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await controller.submitEnergy(
                                overall: overall,
                                tags: Array(tags)
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(controller.isBusy)
                }
            }
            .task {
                await controller.loadEnergy()
                if let current = controller.currentEnergy {
                    overall = current.overall
                    tags = Set(current.tags)
                }
            }
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

private extension RippleVideoAttachment {
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
