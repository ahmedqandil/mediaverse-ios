import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct CreateVibeView: View {
    let onCreated: (VibeSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var slug = ""
    @State private var description = ""
    @State private var visibility: VibeVisibility = .publicVibe
    @State private var joinPolicy: VibeJoinPolicy = .open
    @State private var topics = ""
    @State private var language = ""
    @State private var country = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            WestreemFormPage {
                WestreemFormPanel("Identity") {
                    TextField("Vibe name", text: $name)
                        .onChange(of: name) { _, value in
                            if slug.isEmpty { slug = suggestedSlug(value) }
                        }
                        .westreemField()
                    TextField("Slug", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .westreemField()
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .westreemField(minHeight: 92)
                }
                WestreemFormPanel("Access") {
                    Picker("Visibility", selection: $visibility) {
                        ForEach(VibeVisibility.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .westreemField()
                    Picker("Joining", selection: $joinPolicy) {
                        ForEach(VibeJoinPolicy.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .westreemField()
                }
                WestreemFormPanel(
                    "Discovery",
                    helper: "Add up to 12 topics so people can discover this Vibe."
                ) {
                    TextField("Topics, separated by commas", text: $topics)
                        .westreemField()
                    TextField("Language code (optional)", text: $language)
                        .textInputAutocapitalization(.never)
                        .westreemField()
                    TextField("Country code (optional)", text: $country)
                        .textInputAutocapitalization(.characters)
                        .westreemField()
                }
            }
            .navigationTitle("Create Vibe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .alert(
                "Could not create Vibe",
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

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let created = try await api.createVibe(
                name: name,
                slug: slug,
                description: description,
                visibility: visibility,
                joinPolicy: joinPolicy,
                topics: topicValues(topics),
                language: language,
                country: country
            )
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }
}

struct VibeSettingsView: View {
    let detail: VibeDetailResponse
    let onSaved: (VibeSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var visibility: VibeVisibility
    @State private var joinPolicy: VibeJoinPolicy
    @State private var postingPolicy: VibePostingPolicy
    @State private var commentsEnabled: Bool
    @State private var followersOnly: Bool
    @State private var membersCanInvite: Bool
    @State private var moderatorsCanInvite: Bool
    @State private var moderatorsCanBan: Bool
    @State private var topics: String
    @State private var language: String
    @State private var country: String
    @State private var avatarURL: String?
    @State private var bannerURL: String?
    @State private var avatarFocus: ImageFocus
    @State private var bannerFocus: ImageFocus
    @State private var avatarSelection: PhotosPickerItem?
    @State private var bannerSelection: PhotosPickerItem?
    @State private var avatarSourceImage: UIImage?
    @State private var bannerSourceImage: UIImage?
    @State private var positioningImage: VibeImagePositioning?
    @State private var isUploadingAvatar = false
    @State private var isUploadingBanner = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    init(detail: VibeDetailResponse, onSaved: @escaping (VibeSummary) -> Void) {
        self.detail = detail
        self.onSaved = onSaved
        let club = detail.club
        _name = State(initialValue: club.name)
        _description = State(initialValue: club.description ?? "")
        _visibility = State(initialValue: VibeVisibility(rawValue: club.visibility ?? "") ?? .publicVibe)
        _joinPolicy = State(initialValue: VibeJoinPolicy(rawValue: club.joinPolicy ?? "") ?? .open)
        _postingPolicy = State(initialValue: VibePostingPolicy(rawValue: club.postingPolicy ?? "") ?? .members)
        _commentsEnabled = State(initialValue: club.commentsEnabled)
        _followersOnly = State(initialValue: club.followersOnly)
        _membersCanInvite = State(initialValue: club.membersCanInvite)
        _moderatorsCanInvite = State(initialValue: club.moderatorsCanInvite)
        _moderatorsCanBan = State(initialValue: club.moderatorsCanBan)
        _topics = State(initialValue: club.topics.joined(separator: ", "))
        _language = State(initialValue: club.language ?? "")
        _country = State(initialValue: club.country ?? "")
        _avatarURL = State(initialValue: club.avatarURL)
        _bannerURL = State(initialValue: club.bannerURL)
        _avatarFocus = State(initialValue: ImageFocus(club.avatarFocus))
        _bannerFocus = State(initialValue: ImageFocus(club.bannerFocus))
    }

    private var isPersonal: Bool { detail.club.isPersonal }
    private var isBusy: Bool { isSaving || isUploadingAvatar || isUploadingBanner }

    var body: some View {
        NavigationStack {
            WestreemFormPage {
                WestreemFormPanel("Branding") {
                    profileImagePicker(
                        title: "Avatar",
                        imageURL: avatarURL,
                        selection: $avatarSelection,
                        focus: $avatarFocus,
                        isUploading: isUploadingAvatar,
                        aspectRatio: 1,
                        kind: .avatar
                    )
                    profileImagePicker(
                        title: "Banner",
                        imageURL: bannerURL,
                        selection: $bannerSelection,
                        focus: $bannerFocus,
                        isUploading: isUploadingBanner,
                        aspectRatio: 16.0 / 5.0,
                        kind: .banner
                    )
                }
                WestreemFormPanel("Identity") {
                    TextField("Name", text: $name)
                        .disabled(isPersonal)
                        .westreemField()
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .westreemField(minHeight: 92)
                    TextField("Topics", text: $topics)
                        .westreemField()
                    TextField("Language code", text: $language)
                        .textInputAutocapitalization(.never)
                        .westreemField()
                    TextField("Country code", text: $country)
                        .textInputAutocapitalization(.characters)
                        .westreemField()
                }
                WestreemFormPanel("Access and Posting") {
                    if isPersonal {
                        Toggle("Followers only", isOn: $followersOnly)
                    } else {
                        Picker("Visibility", selection: $visibility) {
                            ForEach(VibeVisibility.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .westreemField()
                        Picker("Joining", selection: $joinPolicy) {
                            ForEach(VibeJoinPolicy.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .westreemField()
                        Picker("Who can post", selection: $postingPolicy) {
                            ForEach(VibePostingPolicy.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .westreemField()
                        Toggle("Members can invite", isOn: $membersCanInvite)
                        Toggle("Moderators can invite", isOn: $moderatorsCanInvite)
                        Toggle("Moderators can ban", isOn: $moderatorsCanBan)
                    }
                    Toggle("Comments enabled", isOn: $commentsEnabled)
                }
            }
            .navigationTitle("Vibe Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isBusy || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task { await upload(item, kind: .avatar) }
            }
            .onChange(of: bannerSelection) { _, item in
                guard let item else { return }
                Task { await upload(item, kind: .banner) }
            }
            .alert(
                "Vibe settings could not be saved",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(item: $positioningImage) { pending in
                WestreemImagePositionEditor(
                    image: pending.image,
                    aspectRatio: pending.kind == .avatar ? 1 : 16.0 / 5.0,
                    title: pending.kind == .avatar ? "Position Avatar" : "Position Banner",
                    onCancel: { positioningImage = nil },
                    onApply: { image in
                        positioningImage = nil
                        Task { await upload(image, kind: pending.kind) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func profileImagePicker(
        title: String,
        imageURL: String?,
        selection: Binding<PhotosPickerItem?>,
        focus: Binding<ImageFocus>,
        isUploading: Bool,
        aspectRatio: CGFloat,
        kind: ProfileImageKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            CachedRemoteImage(url: C.mediaURL(imageURL)) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(focus.wrappedValue.zoom)
                    .offset(
                        x: (focus.wrappedValue.x - 50) * 1.2,
                        y: (focus.wrappedValue.y - 50) * 0.8
                    )
            } placeholder: {
                Rectangle().fill(C.elevated)
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 10) {
                PhotosPicker(selection: selection, matching: .images) {
                    Label(isUploading ? "Uploading…" : "Choose Image", systemImage: "photo")
                }
                if let source = kind == .avatar ? avatarSourceImage : bannerSourceImage {
                    Button {
                        positioningImage = VibeImagePositioning(kind: kind, image: source)
                    } label: {
                        Image(systemName: "crop")
                            .frame(width: 42, height: 36)
                            .background(C.elevated, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .accessibilityLabel("Adjust \(title.lowercased()) position")
                }
            }
            .disabled(isUploading)
            if imageURL != nil {
                HStack {
                    Text("Horizontal")
                    Slider(value: focus.x, in: 0...100)
                }
                HStack {
                    Text("Vertical")
                    Slider(value: focus.y, in: 0...100)
                }
                HStack {
                    Text("Zoom")
                    Slider(value: focus.zoom, in: 1...3)
                }
                .font(.caption)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let settings = VibeSettingsUpdate(
                name: name,
                description: description,
                visibility: visibility,
                joinPolicy: joinPolicy,
                postingPolicy: postingPolicy,
                commentsEnabled: commentsEnabled,
                followersOnly: followersOnly,
                membersCanInvite: membersCanInvite,
                moderatorsCanInvite: moderatorsCanInvite,
                moderatorsCanBan: moderatorsCanBan,
                topics: topicValues(topics),
                language: language.nilIfBlank,
                country: country.nilIfBlank?.uppercased(),
                avatarURL: avatarURL,
                avatarFocus: avatarURL == nil ? nil : avatarFocus.encoded,
                bannerURL: bannerURL,
                bannerFocus: bannerURL == nil ? nil : bannerFocus.encoded
            )
            let saved = try await api.updateVibe(slug: detail.club.slug, settings: settings)
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func upload(_ item: PhotosPickerItem, kind: ProfileImageKind) async {
        if kind == .avatar { isUploadingAvatar = true } else { isUploadingBanner = true }
        defer {
            if kind == .avatar { isUploadingAvatar = false } else { isUploadingBanner = false }
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw LegacySocialAPIError.invalidPhoto
            }
            guard let image = UIImage(data: data) else {
                throw LegacySocialAPIError.invalidPhoto
            }
            await upload(image, kind: kind)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func upload(_ image: UIImage, kind: ProfileImageKind) async {
        if kind == .avatar { isUploadingAvatar = true } else { isUploadingBanner = true }
        defer {
            if kind == .avatar { isUploadingAvatar = false } else { isUploadingBanner = false }
        }
        do {
            guard let data = image.jpegData(compressionQuality: 0.88) else {
                throw LegacySocialAPIError.invalidPhoto
            }
            let uploaded = try await api.uploadVibeProfileImage(
                toVibe: detail.club.slug,
                data: data,
                mimeType: "image/jpeg"
            )
            if kind == .avatar {
                avatarURL = uploaded.imageURL
                avatarSourceImage = image
                avatarFocus = ImageFocus(nil)
            } else {
                bannerURL = uploaded.imageURL
                bannerSourceImage = image
                bannerFocus = ImageFocus(nil)
            }
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }
}

struct VibeWavesManagementView: View {
    let vibeSlug: String
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waves = [VibeWave]()
    @State private var editingWave: VibeWave?
    @State private var presentsCreator = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading Waves…")
                } else if waves.isEmpty {
                    ContentUnavailableView(
                        "No Waves yet",
                        systemImage: "water.waves",
                        description: Text("Create the first space for this Vibe’s conversations.")
                    )
                } else {
                    List {
                        ForEach(waves) { wave in
                            Button {
                                editingWave = wave
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: wave.managementIcon)
                                        .foregroundStyle(C.watch)
                                        .frame(width: 32, height: 32)
                                        .background(C.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(wave.name).font(.subheadline.weight(.semibold))
                                            if wave.isDefault { Text("Default").font(.caption2).foregroundStyle(C.watch) }
                                            if wave.archivedAt != nil { Text("Archived").font(.caption2).foregroundStyle(.orange) }
                                        }
                                        Text("\(wave.managementTypeLabel) · \(wave._count?.posts ?? 0) Ripples · \(wave._count?.events ?? 0) Events")
                                            .font(.caption)
                                            .foregroundStyle(C.textMuted)
                                        Text("\(wave.managementVisibilityLabel) · \(wave.managementPostingLabel)")
                                            .font(.caption2)
                                            .foregroundStyle(C.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(C.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!wave.capabilities.canManage)
                            .opacity(wave.capabilities.canManage ? 1 : 0.65)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(C.bg)
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Manage Waves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { presentsCreator = true } label: {
                        Label("New Wave", systemImage: "plus")
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $presentsCreator) {
                VibeWaveEditorView(vibeSlug: vibeSlug, wave: nil) {
                    presentsCreator = false
                    await load()
                    onChanged()
                }
            }
            .sheet(item: $editingWave) { wave in
                VibeWaveEditorView(vibeSlug: vibeSlug, wave: wave) {
                    editingWave = nil
                    await load()
                    onChanged()
                }
            }
            .alert(
                "Waves couldn’t load",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("Retry") { Task { await load() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @MainActor private func load() async {
        isLoading = waves.isEmpty
        defer { isLoading = false }
        do {
            waves = try await api.vibeWaves(slug: vibeSlug)
            errorMessage = nil
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }
}

private struct VibeWaveEditorView: View {
    let vibeSlug: String
    let wave: VibeWave?
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var slug: String
    @State private var description: String
    @State private var type: VibeWaveType
    @State private var visibility: String
    @State private var postingPolicy: String
    @State private var position: Int
    @State private var commentsEnabled: Bool
    @State private var requiresPostApproval: Bool
    @State private var allowPolls: Bool
    @State private var allowPhotos: Bool
    @State private var allowLinks: Bool
    @State private var allowEchoes: Bool
    @State private var notificationLevel: String
    @State private var pushDelivery: WaveDeliveryOverride
    @State private var emailDelivery: WaveDeliveryOverride
    @State private var isSaving = false
    @State private var confirmsArchive = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    init(vibeSlug: String, wave: VibeWave?, onSaved: @escaping @MainActor () async -> Void) {
        self.vibeSlug = vibeSlug
        self.wave = wave
        self.onSaved = onSaved
        _name = State(initialValue: wave?.name ?? "")
        _slug = State(initialValue: wave?.slug ?? "")
        _description = State(initialValue: wave?.description ?? "")
        _type = State(initialValue: wave?.type ?? .custom)
        _visibility = State(initialValue: wave?.visibility ?? "PUBLIC")
        _postingPolicy = State(initialValue: wave?.postingPolicy ?? "MEMBERS")
        _position = State(initialValue: wave?.position ?? 100)
        _commentsEnabled = State(initialValue: wave?.commentsEnabled ?? true)
        _requiresPostApproval = State(initialValue: wave?.requiresPostApproval ?? false)
        _allowPolls = State(initialValue: wave?.allowPolls ?? true)
        _allowPhotos = State(initialValue: wave?.allowPhotos ?? true)
        _allowLinks = State(initialValue: wave?.allowLinks ?? true)
        _allowEchoes = State(initialValue: wave?.allowEchoes ?? true)
        _notificationLevel = State(initialValue: wave?.subscription?.notificationLevel ?? "INHERIT")
        _pushDelivery = State(initialValue: WaveDeliveryOverride(wave?.subscription?.pushEnabled))
        _emailDelivery = State(initialValue: WaveDeliveryOverride(wave?.subscription?.emailEnabled))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            WestreemFormPage {
                WestreemFormPanel("Identity") {
                    TextField("Wave name", text: $name)
                        .onChange(of: name) { _, value in
                            if wave == nil { slug = suggestedSlug(value) }
                        }
                        .westreemField()
                    TextField("Address", text: $slug)
                        .disabled(wave?.isSystem == true)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .westreemField()
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                        .westreemField(minHeight: 78)
                    Picker("Wave type", selection: $type) {
                        ForEach(VibeWaveType.managementCases, id: \.self) { Text($0.managementLabel).tag($0) }
                    }
                    .disabled(wave != nil)
                    .onChange(of: type) { _, _ in applyTypeInvariantsToEditor() }
                    .westreemField()
                    Stepper("Position \(position)", value: $position, in: 0...999)
                }
                WestreemFormPanel("Access") {
                    Picker("Who can view", selection: $visibility) {
                        Text("Everyone").tag("PUBLIC")
                        Text("Members").tag("MEMBERS")
                        Text("Staff").tag("STAFF")
                    }
                    .disabled(type == .staff)
                    .westreemField()
                    Picker("Who can post", selection: $postingPolicy) {
                        Text("Everyone").tag("EVERYONE")
                        Text("Members").tag("MEMBERS")
                        Text("Moderators").tag("MODERATORS")
                        Text("Administrators").tag("ADMINS")
                    }
                    .disabled(type == .announcements || type == .events || type == .staff)
                    .westreemField()
                    Toggle("Require post approval", isOn: $requiresPostApproval)
                        .disabled(type == .announcements || type == .events)
                    Toggle("Comments", isOn: $commentsEnabled)
                        .disabled(type == .questions)
                }
                WestreemFormPanel("Ripple tools") {
                    Toggle("Polls", isOn: $allowPolls)
                        .disabled(type == .announcements || type == .events)
                    Toggle("Photos", isOn: $allowPhotos)
                    Toggle("Links", isOn: $allowLinks)
                        .disabled(type == .resources)
                    Toggle("Echoes", isOn: $allowEchoes)
                    if let invariantSummary = type.managementInvariantSummary {
                        Text(invariantSummary)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                if wave != nil {
                    WestreemFormPanel(
                        "Notifications",
                        helper: notificationLevel == "INHERIT"
                            ? "This Wave currently uses your Vibe activity preference."
                            : "This Wave overrides your Vibe activity preference."
                    ) {
                        Picker("Notify me", selection: $notificationLevel) {
                            Text("Use Vibe setting").tag("INHERIT")
                            Text("All activity").tag("ALL")
                            Text("Highlights").tag("HIGHLIGHTS")
                            Text("Mentions only").tag("MENTIONS")
                            Text("Off").tag("OFF")
                        }
                        .westreemField()
                        Picker("Push notifications", selection: $pushDelivery) {
                            Text("Use Vibe setting").tag(WaveDeliveryOverride.inherit)
                            Text("On").tag(WaveDeliveryOverride.enabled)
                            Text("Off").tag(WaveDeliveryOverride.disabled)
                        }
                        .westreemField()
                        Picker("Email notifications", selection: $emailDelivery) {
                            Text("Use Vibe setting").tag(WaveDeliveryOverride.inherit)
                            Text("On").tag(WaveDeliveryOverride.enabled)
                            Text("Off").tag(WaveDeliveryOverride.disabled)
                        }
                        .westreemField()
                        if notificationLevel == "OFF" {
                            Text("Delivery channel choices are retained for when you turn Wave notifications back on.")
                                .font(.caption)
                                .foregroundStyle(C.textMuted)
                        }
                    }
                }
                if let wave,
                   VibeWaveManagementPolicy.canArchive(
                       isSystem: wave.isSystem,
                       isDefault: wave.isDefault,
                       isArchived: wave.archivedAt != nil,
                       serverAllowsArchive: wave.capabilities.canArchive
                   ) || VibeWaveManagementPolicy.canRestore(
                       isSystem: wave.isSystem,
                       isDefault: wave.isDefault,
                       isArchived: wave.archivedAt != nil,
                       serverAllowsManagement: wave.capabilities.canManage
                   ) {
                    WestreemFormPanel("Lifecycle") {
                        Button(wave.archivedAt == nil ? "Archive Wave" : "Restore Wave", role: wave.archivedAt == nil ? .destructive : nil) {
                            if wave.archivedAt == nil { confirmsArchive = true }
                            else { Task { await restore() } }
                        }
                    }
                }
            }
            .navigationTitle(wave == nil ? "New Wave" : "Wave Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Archive this Wave?", isPresented: $confirmsArchive, titleVisibility: .visible) {
                Button("Archive Wave", role: .destructive) { Task { await archive() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New Ripples will stop, but existing content remains available to Vibe managers.")
            }
            .alert(
                "Wave couldn’t be saved",
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

    @MainActor private func save() async {
        isSaving = true
        defer { isSaving = false }
        let settings = VibeWaveManagementPolicy.normalized(VibeWaveSettings(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: slug,
            description: description.nilIfBlank,
            type: type,
            visibility: visibility,
            postingPolicy: postingPolicy,
            position: position,
            commentsEnabled: commentsEnabled,
            requiresPostApproval: requiresPostApproval,
            allowPolls: allowPolls,
            allowPhotos: allowPhotos,
            allowLinks: allowLinks,
            allowEchoes: allowEchoes
        ))
        do {
            if let wave {
                try await api.updateVibeWave(vibeSlug: vibeSlug, waveSlug: wave.slug, settings: settings)
                _ = try await api.updateWaveNotificationSettings(
                    vibeSlug: vibeSlug,
                    waveSlug: slug,
                    notificationLevel: notificationLevel,
                    pushEnabled: pushDelivery.apiValue,
                    emailEnabled: emailDelivery.apiValue
                )
            } else {
                try await api.createVibeWave(vibeSlug: vibeSlug, settings: settings)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func applyTypeInvariantsToEditor() {
        switch type {
        case .announcements, .events:
            postingPolicy = "ADMINS"
            requiresPostApproval = false
            allowPolls = false
        case .staff:
            visibility = "STAFF"
            postingPolicy = "MODERATORS"
        case .questions:
            commentsEnabled = true
        case .resources:
            allowLinks = true
        case .general, .media, .custom, .unknown:
            break
        }
    }

    @MainActor private func archive() async {
        guard let wave else { return }
        do {
            try await api.archiveVibeWave(vibeSlug: vibeSlug, waveSlug: wave.slug)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    @MainActor private func restore() async {
        guard let wave else { return }
        do {
            try await api.restoreVibeWave(vibeSlug: vibeSlug, waveSlug: wave.slug)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }
}

private extension VibeWaveType {
    static let managementCases: [VibeWaveType] = [
        .general, .announcements, .questions, .events, .resources, .media, .staff, .custom,
    ]

    var managementLabel: String {
        switch self {
        case .general: "General"
        case .announcements: "Announcements"
        case .questions: "Questions"
        case .events: "Events"
        case .resources: "Resources"
        case .media: "Media"
        case .staff: "Staff"
        case .custom: "Custom"
        case .unknown(let value): value.capitalized
        }
    }

    var managementInvariantSummary: String? {
        switch self {
        case .announcements: "Announcements are administrator-only and do not support polls or approval queues."
        case .events: "Event creation is administrator-only and does not support polls or approval queues."
        case .staff: "Staff Waves are visible to staff and accept posts from moderators."
        case .questions: "Questions always keep comments enabled so answers can be submitted."
        case .resources: "Resources always keep links enabled."
        case .general, .media, .custom, .unknown: nil
        }
    }
}

private extension VibeWave {
    var managementTypeLabel: String { type.managementLabel }

    var managementVisibilityLabel: String {
        switch visibility {
        case "PUBLIC": "Public"
        case "MEMBERS": "Members"
        case "STAFF": "Staff"
        default: "Restricted"
        }
    }

    var managementPostingLabel: String {
        switch postingPolicy {
        case "EVERYONE": "Everyone can post"
        case "MEMBERS": "Members can post"
        case "MODERATORS": "Moderators can post"
        case "ADMINS": "Administrators can post"
        default: "Posting restricted"
        }
    }

    var managementIcon: String {
        switch type {
        case .announcements: "megaphone"
        case .questions: "questionmark.bubble"
        case .events: "calendar"
        case .resources: "bookmark"
        case .media: "play.rectangle"
        case .staff: "lock.shield"
        case .general, .custom, .unknown: "water.waves"
        }
    }
}

private enum ProfileImageKind { case avatar, banner }

private struct VibeImagePositioning: Identifiable {
    let kind: ProfileImageKind
    let image: UIImage
    var id: String { kind == .avatar ? "avatar" : "banner" }
}

private struct ImageFocus {
    var x: Double = 50
    var y: Double = 50
    var zoom: Double = 1

    init(_ value: String?) {
        let parts = value?.split(separator: " ").map(String.init) ?? []
        if parts.count == 3 {
            x = Double(parts[0].replacingOccurrences(of: "%", with: "")) ?? 50
            y = Double(parts[1].replacingOccurrences(of: "%", with: "")) ?? 50
            zoom = Double(parts[2]) ?? 1
        }
    }

    var encoded: String {
        "\(Int(x.rounded()))% \(Int(y.rounded()))% \(String(format: "%.2f", zoom))"
    }
}

private func topicValues(_ value: String) -> [String] {
    value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func suggestedSlug(_ value: String) -> String {
    value.lowercased()
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
