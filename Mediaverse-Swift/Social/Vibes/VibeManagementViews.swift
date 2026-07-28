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
