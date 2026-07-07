import SwiftUI

/// User profile — avatar, name, stats, settings rows, context switcher, sign out.
struct ProfileView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var profile: FullProfile?
    @State private var contexts       = [ActiveContext]()
    @State private var activeCtx: ActiveContext?
    @State private var isLoading      = true
    @State private var showCtxSwitcher = false
    @State private var showHistory    = false
    @State private var showPlaylists  = false
    @State private var showCollections = false
    @State private var showEditProfile = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !auth.isAuthenticated {
                unauthState
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        profileHero
                        quickActions
                        accountSection
                        signOutButton
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCtxSwitcher) {
            ContextSwitcherView(
                contexts: $contexts,
                active: $activeCtx
            ) { _ in }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet(profile: profile) { updated in
                profile = updated
            }
        }
        .navigationDestination(isPresented: $showHistory) {
            WatchHistoryView()
        }
        .navigationDestination(isPresented: $showPlaylists) {
            PlaylistsView()
        }
        .navigationDestination(isPresented: $showCollections) {
            CollectionsView()
        }
        .task {
            guard auth.isAuthenticated else { isLoading = false; return }
            await loadAll()
        }
    }

    // MARK: - Profile header

    private var profileHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: C.mediaURL(profile?.bannerUrl ?? profile?.channel?.bannerUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(
                        colors: [C.watch.opacity(0.34), Color.white.opacity(0.08), C.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(height: 138)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.06), .black.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                HStack(alignment: .bottom, spacing: 14) {
                    profileAvatar
                        .offset(y: 28)

                    Spacer()

                    Button {
                        showEditProfile = true
                    } label: {
                        HStack(spacing: 6) {
                            MediaverseIcon(name: "edit", fallbackSystemName: "pencil")
                                .frame(width: 13, height: 13)
                            Text("Edit")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(C.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.38))
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.name ?? (isLoading ? "Loading..." : auth.currentUser?.name ?? "Profile"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)

                        if let handle = profile?.handle, !handle.isEmpty {
                            Text("@\(handle)")
                                .font(.subheadline)
                                .foregroundStyle(C.textMuted)
                        } else if let email = profile?.email ?? auth.currentUser?.email {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(C.textMuted)
                        }
                    }

                    Spacer()
                    contextChip
                }

                if let bio = profile?.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(C.text.opacity(0.74))
                        .lineSpacing(2)
                        .lineLimit(4)
                }

                HStack(spacing: 10) {
                    statPill(value: fmtCount(profile?.channel?.followerCount ?? 0), label: "Followers")
                    statPill(value: contexts.isEmpty ? "1" : "\(contexts.count)", label: "Contexts")
                    statPill(value: profile?.role?.capitalized ?? "User", label: "Role")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)
            .padding(.bottom, 16)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(C.border, lineWidth: 1) }
    }

    private var profileAvatar: some View {
        AsyncImage(url: C.mediaURL(profile?.image)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(C.surfaceAlt)
                MediaverseIcon(name: "user", fallbackSystemName: "person")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(Circle())
        .overlay { Circle().stroke(C.bg, lineWidth: 5) }
        .overlay { Circle().stroke(C.border, lineWidth: 1) }
    }

    @ViewBuilder
    private var contextChip: some View {
        if let ctx = activeCtx {
            Button {
                if contexts.count > 1 {
                    showCtxSwitcher = true
                }
            } label: {
                HStack(spacing: 6) {
                    MediaverseIcon(name: contextIconName(ctx.type), fallbackSystemName: ctxIcon(ctx.type))
                        .frame(width: 12, height: 12)
                    Text(ctx.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if contexts.count > 1 {
                        MediaverseIcon(name: "chevron-down", fallbackSystemName: "chevron.down")
                            .frame(width: 8, height: 8)
                    }
                }
                .foregroundStyle(C.watch)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(C.watch.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(C.text)
            Text(label)
                .font(.caption2)
                .foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Mobile web sections

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your Library")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                quickActionTile(iconName: "history", fallbackSystemName: "clock", title: "History", subtitle: "Resume watching") {
                    showHistory = true
                }
                quickActionTile(iconName: "playlist", fallbackSystemName: "list.bullet.rectangle", title: "Playlists", subtitle: "Saved queues") {
                    showPlaylists = true
                }
                quickActionTile(iconName: "collection", fallbackSystemName: "square.grid.2x2", title: "Collections", subtitle: "Clips and shows") {
                    showCollections = true
                }
                quickActionTile(iconName: "user", fallbackSystemName: "person.crop.circle", title: "Edit Profile", subtitle: "Avatar and banner") {
                    showEditProfile = true
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account")
            VStack(spacing: 0) {
                if contexts.count > 1 {
                    accountRow(iconName: "switch", fallbackSystemName: "arrow.triangle.2.circlepath", title: "Switch Context", subtitle: activeCtx?.name) {
                        showCtxSwitcher = true
                    }
                    rowDivider
                }
                accountRow(iconName: "user", fallbackSystemName: "person.crop.circle", title: "Edit Profile", subtitle: "Name and bio") {
                    showEditProfile = true
                }
            }
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
        }
    }

    private func quickActionTile(iconName: String, fallbackSystemName: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(C.watch)
                    .frame(width: 42, height: 42)
                    .background(C.watch.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(C.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func pillAction(iconName: String, fallbackSystemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(C.watch)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func accountRow(iconName: String, fallbackSystemName: String, title: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MediaverseIcon(name: iconName, fallbackSystemName: fallbackSystemName)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(C.watch)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                MediaverseIcon(name: "chevron-right", fallbackSystemName: "chevron.right")
                    .frame(width: 11, height: 11)
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var signOutButton: some View {
        Button {
            Task { await auth.signOut() }
        } label: {
            HStack(spacing: 10) {
                MediaverseIcon(name: "logout", fallbackSystemName: "rectangle.portrait.and.arrow.right")
                    .frame(width: 17, height: 17)
                Text("Sign Out")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.18), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(C.textMuted)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private var rowDivider: some View {
        Divider()
            .background(C.border)
            .padding(.leading, 62)
    }

    // MARK: - Unauth

    private var unauthState: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle")
                .font(.system(size: 64))
                .foregroundStyle(C.textMuted)
            Text("Sign in to your account")
                .font(.title3.bold())
                .foregroundStyle(C.text)
            Text("Track your watch history, follow shows and channels, and more.")
                .font(.subheadline)
                .foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(C.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    private func loadAll() async {
        isLoading = true
        async let profTask   = APIClient.shared.fetchProfile()
        async let ctxTask    = APIClient.shared.fetchContexts()

        let (profResult, ctxResult) = (
            try? await profTask,
            try? await ctxTask
        )

        if let p = profResult { profile = p.profile }
        if let c = ctxResult {
            contexts   = c.contexts
            activeCtx  = c.active
        }
        isLoading = false
    }

    private func ctxIcon(_ type: String) -> String {
        switch type {
        case "admin":   return "shield.fill"
        case "network": return "building.2.fill"
        case "channel": return "play.rectangle.fill"
        default:        return "person.fill"
        }
    }

    private func contextIconName(_ type: String) -> String {
        switch type {
        case "admin": return "shield"
        case "network": return "network"
        case "channel": return "play"
        default: return "user"
        }
    }

    private func fmtCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct EditProfileSheet: View {
    let profile: FullProfile?
    let onSaved: (FullProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var bio: String
    @State private var image: String
    @State private var bannerUrl: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(profile: FullProfile?, onSaved: @escaping (FullProfile) -> Void) {
        self.profile = profile
        self.onSaved = onSaved
        _name = State(initialValue: profile?.name ?? "")
        _bio = State(initialValue: profile?.bio ?? "")
        _image = State(initialValue: profile?.image ?? "")
        _bannerUrl = State(initialValue: profile?.bannerUrl ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        fieldGroup("Display name") {
                            TextField("Your name", text: $name)
                                .textFieldStyle(.plain)
                                .foregroundStyle(C.text)
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        fieldGroup("Bio") {
                            ZStack(alignment: .topLeading) {
                                if bio.isEmpty {
                                    Text("A short description about you...")
                                        .foregroundStyle(C.textMuted)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 14)
                                }
                                TextEditor(text: $bio)
                                    .frame(minHeight: 120)
                                    .foregroundStyle(C.text)
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        fieldGroup("Profile image URL") {
                            TextField("https://...", text: $image)
                                .textFieldStyle(.plain)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(C.text)
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        fieldGroup("Banner image URL") {
                            TextField("https://...", text: $bannerUrl)
                                .textFieldStyle(.plain)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(C.text)
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(C.border, lineWidth: 1) }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(C.pagePad)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(C.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(C.watch)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func fieldGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            content()
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = image.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBanner = bannerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        saving = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.updateProfile(
                name: trimmedName,
                bio: trimmedBio.isEmpty ? nil : trimmedBio,
                image: trimmedImage.isEmpty ? nil : trimmedImage,
                bannerUrl: trimmedBanner.isEmpty ? nil : trimmedBanner
            )
            onSaved(resp.profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
