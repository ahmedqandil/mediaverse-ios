import SwiftUI

/// User profile — avatar, name, stats, settings rows, context switcher, sign out.
struct ProfileView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var profile: FullProfile?
    @State private var contexts       = [ActiveContext]()
    @State private var activeCtx: ActiveContext?
    @State private var isLoading      = true
    @State private var showCtxSwitcher = false
    @State private var showNotifs     = false
    @State private var showHistory    = false
    @State private var showPlaylists  = false
    @State private var showUpload     = false
    @State private var showStudio     = false
    @State private var showCollections = false
    @State private var showEditProfile = false
    @State private var unreadCount    = 0

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            if !auth.isAuthenticated {
                unauthState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        profileHeader
                        Divider().background(C.border).padding(.vertical, 16)
                        settingsList
                    }
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNotifs = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .foregroundStyle(C.text)
                        if unreadCount > 0 {
                            Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(3)
                                .background(C.watch)
                                .clipShape(Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCtxSwitcher) {
            ContextSwitcherView(
                contexts: $contexts,
                active: $activeCtx
            ) { _ in }
        }
        .sheet(isPresented: $showNotifs) {
            NotificationsView()
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
        .navigationDestination(isPresented: $showUpload) {
            UploadView()
        }
        .navigationDestination(isPresented: $showStudio) {
            StudioView()
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

    private var profileHeader: some View {
        VStack(spacing: 16) {
            if isLoading {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 88, height: 88)
            } else {
                AsyncImage(url: C.mediaURL(profile?.image)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Circle().fill(C.surface)
                        Image(systemName: "person.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(C.textMuted)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay { Circle().stroke(C.border, lineWidth: 1) }
            }

            VStack(spacing: 4) {
                Text(profile?.name ?? (isLoading ? "Loading…" : auth.currentUser?.name ?? ""))
                    .font(.title3.bold())
                    .foregroundStyle(C.text)
                if let email = profile?.email ?? auth.currentUser?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(C.textMuted)
                }
            }

            // Active context chip
            if let ctx = activeCtx {
                HStack(spacing: 6) {
                    Image(systemName: ctxIcon(ctx.type))
                        .font(.caption2)
                    Text(ctx.name)
                        .font(.caption.weight(.semibold))
                    if contexts.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(C.watch)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(C.watch.opacity(0.1))
                .clipShape(Capsule())
                .onTapGesture {
                    if contexts.count > 1 { showCtxSwitcher = true }
                }
            }
        }
        .padding(.horizontal, C.pagePad)
        .padding(.top, 8)
    }

    // MARK: - Settings list

    private var settingsList: some View {
        VStack(spacing: 0) {
            // Context switcher row (only if user has multiple contexts)
            if contexts.count > 1 {
                settingsRow(icon: "arrow.triangle.2.circlepath", label: "Switch Context") {
                    showCtxSwitcher = true
                }
                Divider().background(C.border).padding(.leading, C.pagePad + 36)
            }

            settingsRow(icon: "bell", label: "Notifications") {
                showNotifs = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "clock", label: "Watch History") {
                showHistory = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "list.bullet.rectangle.portrait", label: "My Playlists") {
                showPlaylists = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "arrow.up.to.line.compact", label: "Upload Content") {
                showUpload = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "sparkles", label: "AI Studio") {
                showStudio = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "person.crop.circle", label: "Edit Profile") {
                showEditProfile = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            settingsRow(icon: "square.and.arrow.down", label: "Collections") {
                showCollections = true
            }
            Divider().background(C.border).padding(.leading, C.pagePad + 36)

            // Sign out
            Button {
                Task { await auth.signOut() }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.red)
                        .frame(width: 36)
                    Text("Sign Out")
                        .font(.body)
                        .foregroundStyle(Color.red)
                    Spacer()
                }
                .padding(.horizontal, C.pagePad)
                .padding(.vertical, 14)
            }
        }
    }

    private func settingsRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(C.watch)
                    .frame(width: 36)
                Text(label)
                    .font(.body)
                    .foregroundStyle(C.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(C.textMuted)
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 14)
        }
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
        async let notifTask  = APIClient.shared.fetchNotificationCounts()

        let (profResult, ctxResult, notifResult) = (
            try? await profTask,
            try? await ctxTask,
            try? await notifTask
        )

        if let p = profResult { profile = p.profile }
        if let c = ctxResult {
            contexts   = c.contexts
            activeCtx  = c.active
        }
        if let n = notifResult {
            unreadCount = n.values.reduce(0, +)
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
}

private struct EditProfileSheet: View {
    let profile: FullProfile?
    let onSaved: (FullProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var bio: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(profile: FullProfile?, onSaved: @escaping (FullProfile) -> Void) {
        self.profile = profile
        self.onSaved = onSaved
        _name = State(initialValue: profile?.name ?? "")
        _bio = State(initialValue: profile?.bio ?? "")
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
        guard !trimmedName.isEmpty else { return }
        saving = true
        errorMessage = nil
        do {
            let resp = try await APIClient.shared.updateProfile(
                name: trimmedName,
                bio: trimmedBio.isEmpty ? nil : trimmedBio
            )
            onSaved(resp.profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
