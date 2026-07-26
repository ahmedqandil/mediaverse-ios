import SwiftUI

struct VibeInvitationsView: View {
    let slug: String
    let capabilities: VibeCapabilities
    let currentRole: String?

    @Environment(\.dismiss) private var dismiss
    @State private var invites: [VibeInvite] = []
    @State private var email = ""
    @State private var role: VibeInviteRole = .member
    @State private var expiresInDays = 7
    @State private var maxUses = 1
    @State private var generatedURL: URL?
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    private var allowedRoles: [VibeInviteRole] {
        var roles: [VibeInviteRole] = [.member]
        if capabilities.canManageRoles { roles.append(.moderator) }
        if currentRole == "OWNER" { roles.append(.admin) }
        return roles
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email (optional)", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    Picker("Role", selection: $role) {
                        ForEach(allowedRoles, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Expires", selection: $expiresInDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    Stepper("Maximum uses: \(maxUses)", value: $maxUses, in: 1...100)
                        .disabled(!email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(isBusy ? "Creating…" : "Generate Invitation") {
                        Task { await createInvite() }
                    }
                    .disabled(isBusy)
                } header: {
                    Text("Create Invitation")
                } footer: {
                    Text("Leave email blank for a shareable member link. Targeted invitations can be used once.")
                }

                if let generatedURL {
                    Section("New Invitation") {
                        Text(generatedURL.absoluteString)
                            .font(.footnote)
                            .textSelection(.enabled)
                        ShareLink(item: generatedURL) {
                            Label("Share Invitation", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Invitation History") {
                    if isLoading {
                        ProgressView()
                    } else if invites.isEmpty {
                        Text("No invitations yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(invites) { invite in
                            inviteRow(invite)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg)
            .navigationTitle("Invitations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert(
                "Invitation update failed",
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

    @ViewBuilder
    private func inviteRow(_ invite: VibeInvite) -> some View {
        let status = inviteStatus(invite)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(invite.invitedEmail ?? invite.invitedUser?.name ?? "Shareable link")
                    .font(.subheadline.weight(.semibold))
                Text("\(invite.role.label) · \(invite.useCount)/\(invite.maxUses) uses · \(status.label)")
                    .font(.caption)
                    .foregroundStyle(status.color)
            }
            Spacer()
            if status.isActive {
                Button("Revoke", role: .destructive) {
                    Task { await revoke(invite) }
                }
                .font(.caption.weight(.semibold))
                .disabled(isBusy)
            }
        }
    }

    private func load() async {
        isLoading = true
        do {
            invites = try await api.vibeInvites(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func createInvite() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let targeted = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let result = try await api.createVibeInvite(
                slug: slug,
                invitedEmail: email,
                role: role,
                expiresInDays: expiresInDays,
                maxUses: targeted ? 1 : maxUses
            )
            generatedURL = URL(string: "https://www.westreem.com/vibes/invite/\(result.token)")
            email = ""
            role = .member
            invites = try await api.vibeInvites(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func revoke(_ invite: VibeInvite) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await api.revokeVibeInvite(slug: slug, inviteID: invite.id)
            invites = try await api.vibeInvites(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }

    private func inviteStatus(_ invite: VibeInvite) -> InviteStatus {
        if invite.revokedAt != nil { return .revoked }
        if invite.acceptedAt != nil || invite.useCount >= invite.maxUses { return .accepted }
        if let value = invite.expiresAt,
           let date = ISO8601DateFormatter().date(from: value),
           date < Date() {
            return .expired
        }
        return .active
    }
}

private enum InviteStatus {
    case active, revoked, accepted, expired

    var label: String {
        switch self {
        case .active: "active"
        case .revoked: "revoked"
        case .accepted: "accepted"
        case .expired: "expired"
        }
    }

    var isActive: Bool { self == .active }
    var color: Color {
        switch self {
        case .active: C.watch
        case .revoked, .expired: .secondary
        case .accepted: .green
        }
    }
}

struct VibeInviteAcceptView: View {
    let token: String
    @State private var isAccepting = false
    @State private var acceptedSlug: String?
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: acceptedSlug == nil ? "person.2.badge.plus" : "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(C.watch)
            Text(acceptedSlug == nil ? "Vibe Invitation" : "Invitation Accepted")
                .font(.title2.bold())
            Text(acceptedSlug == nil
                 ? "Join this Vibe using your Westreem account."
                 : "You are now a member of this Vibe.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let acceptedSlug {
                NavigationLink(value: AppRoute.vibe(acceptedSlug)) {
                    Text("Open Vibe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
            } else {
                Button(isAccepting ? "Accepting…" : "Accept Invitation") {
                    Task { await accept() }
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(isAccepting)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Invitation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func accept() async {
        isAccepting = true
        errorMessage = nil
        defer { isAccepting = false }
        do {
            acceptedSlug = try await api.acceptVibeInvite(token: token).slug
        } catch {
            errorMessage = socialErrorMessage(error)
        }
    }
}
