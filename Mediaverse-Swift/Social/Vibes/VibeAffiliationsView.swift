import SwiftUI

struct VibeAffiliationsView: View {
    let slug: String
    @Environment(\.dismiss) private var dismiss
    @State private var affiliations: [VibeAffiliation] = []
    @State private var entityType: VibeAffiliationEntityType = .show
    @State private var query = ""
    @State private var results: [VibeAffiliationTarget] = []
    @State private var requestMessage = ""
    @State private var selectedTarget: VibeAffiliationTarget?
    @State private var isPrimary = false
    @State private var isLoading = true
    @State private var isSearching = false
    @State private var busyID: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var notice: String?

    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    requestSection
                    historySection
                }
                .padding(C.pagePad)
            }
            .background(C.bg.ignoresSafeArea())
            .foregroundStyle(C.text)
            .navigationTitle("Affiliations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .onDisappear { searchTask?.cancel() }
            .alert(
                "Affiliation update failed",
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

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Request an affiliation", systemImage: "link")
                .font(.headline)
            Text("Connect this Vibe with an official Show or Channel. Its owner must approve the request.")
                .font(.caption)
                .foregroundStyle(C.textMuted)

            Picker("Entity", selection: $entityType) {
                Text("Shows").tag(VibeAffiliationEntityType.show)
                Text("Channels").tag(VibeAffiliationEntityType.channel)
            }
            .pickerStyle(.segmented)
            .onChange(of: entityType) { _, _ in
                query = ""
                results = []
                selectedTarget = nil
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(C.textMuted)
                TextField(
                    entityType == .show ? "Search shows" : "Search channels",
                    text: $query
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if isSearching {
                    ProgressView().controlSize(.small).tint(C.watch)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(C.elevated, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: query) { _, value in scheduleSearch(value) }

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(results) { target in
                        Button {
                            selectedTarget = target
                        } label: {
                            HStack(spacing: 10) {
                                SocialIdentityAvatar(
                                    image: target.imageURL,
                                    name: target.name,
                                    size: 38
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name).font(.subheadline.bold())
                                    if let handle = target.handle {
                                        Text("@\(handle)").font(.caption).foregroundStyle(C.textMuted)
                                    }
                                }
                                Spacer()
                                Image(systemName: selectedTarget?.id == target.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTarget?.id == target.id ? C.watch : C.textMuted)
                            }
                            .padding(10)
                        }
                        .buttonStyle(.plain)
                        if target.id != results.last?.id {
                            Divider().overlay(C.borderSubtle)
                        }
                    }
                }
                .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            if let target = selectedTarget {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Requesting \(target.name)")
                        .font(.subheadline.bold())
                    TextField("Optional message to the owner", text: $requestMessage, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(10)
                        .background(C.elevated, in: RoundedRectangle(cornerRadius: 9))
                    Toggle("Primary affiliation", isOn: $isPrimary)
                        .font(.subheadline)
                    Button {
                        Task { await submit(target) }
                    } label: {
                        if busyID == target.id {
                            ProgressView().tint(C.bg)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Send request")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(C.watch)
                    .disabled(busyID != nil)
                }
                .padding(12)
                .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            if let notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.watch)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requests").font(.headline)
            if isLoading {
                ProgressView().tint(C.watch).frame(maxWidth: .infinity).padding()
            } else if affiliations.isEmpty {
                Text("No affiliation requests yet.")
                    .font(.subheadline)
                    .foregroundStyle(C.textMuted)
                    .padding(.vertical, 8)
            } else {
                ForEach(affiliations) { affiliation in
                    affiliationRow(affiliation)
                }
            }
        }
    }

    private func affiliationRow(_ affiliation: VibeAffiliation) -> some View {
        HStack(spacing: 11) {
            SocialIdentityAvatar(
                image: affiliation.entity?.imageURL,
                name: affiliation.entity?.displayName,
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(affiliation.entity?.displayName ?? affiliation.entityType.rawValue.capitalized)
                    .font(.subheadline.bold())
                Text(statusLabel(affiliation.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(affiliation.status))
                if let note = affiliation.reviewNote, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                }
            }
            Spacer()
            if affiliation.status == .pending || affiliation.status == .approved {
                Button("Cancel", role: .destructive) {
                    Task { await cancel(affiliation) }
                }
                .font(.caption.bold())
                .disabled(busyID != nil)
            }
        }
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            affiliations = try await api.vibeAffiliations(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                results = try await api.affiliationTargets(
                    slug: slug,
                    type: entityType,
                    query: normalized
                )
            } catch {
                results = []
                errorMessage = socialErrorMessage(error)
            }
            isSearching = false
        }
    }

    @MainActor
    private func submit(_ target: VibeAffiliationTarget) async {
        guard busyID == nil else { return }
        busyID = target.id
        do {
            _ = try await api.requestAffiliation(
                slug: slug,
                entityType: target.type,
                entityId: target.id,
                message: requestMessage,
                isPrimary: isPrimary
            )
            notice = "Request sent to \(target.name)."
            selectedTarget = nil
            requestMessage = ""
            isPrimary = false
            query = ""
            results = []
            affiliations = try await api.vibeAffiliations(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        busyID = nil
    }

    @MainActor
    private func cancel(_ affiliation: VibeAffiliation) async {
        guard busyID == nil else { return }
        busyID = affiliation.id
        do {
            try await api.cancelAffiliation(slug: slug, affiliationId: affiliation.id)
            notice = "Affiliation request cancelled."
            affiliations = try await api.vibeAffiliations(slug: slug)
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        busyID = nil
    }

    private func statusLabel(_ status: VibeAffiliationStatus) -> String {
        switch status {
        case .pending: "Pending review"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .revoked: "Revoked"
        case .cancelled: "Cancelled"
        }
    }

    private func statusColor(_ status: VibeAffiliationStatus) -> Color {
        switch status {
        case .pending: .orange
        case .approved: C.watch
        case .rejected, .revoked: .red
        case .cancelled: C.textMuted
        }
    }
}

struct AffiliationReviewView: View {
    @State private var queue: AffiliationReviewQueueResponse?
    @State private var status: VibeAffiliationStatus = .pending
    @State private var selected: VibeAffiliation?
    @State private var action: AffiliationReviewAction = .approve
    @State private var note = ""
    @State private var relationship: VibeAffiliationRelationship = .affiliatedCommunity
    @State private var isLoading = true
    @State private var busyID: String?
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let counts = queue?.counts {
                    HStack(spacing: 10) {
                        countTile("Pending", counts.pending)
                        countTile("Approved", counts.approved)
                        countTile("Total", counts.total)
                    }
                }
                Picker("Status", selection: $status) {
                    Text("Pending").tag(VibeAffiliationStatus.pending)
                    Text("Approved").tag(VibeAffiliationStatus.approved)
                    Text("Rejected").tag(VibeAffiliationStatus.rejected)
                    Text("Revoked").tag(VibeAffiliationStatus.revoked)
                }
                .pickerStyle(.segmented)

                if isLoading {
                    ProgressView().tint(C.watch).frame(maxWidth: .infinity).padding(.top, 40)
                } else if queue?.affiliations.isEmpty != false {
                    ContentUnavailableView(
                        "No \(statusLabel.lowercased()) requests",
                        systemImage: "link",
                        description: Text("Requests for Shows and Channels you can manage appear here.")
                    )
                    .foregroundStyle(C.text)
                    .padding(.top, 30)
                } else {
                    ForEach(queue?.affiliations ?? []) { affiliation in
                        reviewRow(affiliation)
                    }
                }
            }
            .padding(C.pagePad)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle("Affiliation Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: status.rawValue) { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { affiliation in
            decisionSheet(affiliation)
        }
        .alert(
            "Affiliation review failed",
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

    private var statusLabel: String {
        switch status {
        case .pending: "Pending"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .revoked: "Revoked"
        case .cancelled: "Cancelled"
        }
    }

    private func countTile(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title3.bold()).foregroundStyle(C.text)
            Text(title).font(.caption).foregroundStyle(C.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reviewRow(_ affiliation: VibeAffiliation) -> some View {
        Button {
            action = affiliation.status == .approved ? .revoke : .approve
            note = ""
            relationship = affiliation.relationshipType
            selected = affiliation
        } label: {
            HStack(spacing: 11) {
                SocialIdentityAvatar(
                    image: affiliation.requestedBy?.image,
                    name: affiliation.club?.name,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(affiliation.club?.name ?? "Vibe").font(.subheadline.bold())
                    Text("to \(affiliation.entity?.displayName ?? affiliation.entityType.rawValue.capitalized)")
                        .font(.caption).foregroundStyle(C.textMuted)
                    if let message = affiliation.requestMessage, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(C.textMuted).lineLimit(2)
                    }
                }
                Spacer()
                if busyID == affiliation.id {
                    ProgressView().controlSize(.small).tint(C.watch)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(C.textMuted)
                }
            }
            .padding(12)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(busyID != nil)
    }

    private func decisionSheet(_ affiliation: VibeAffiliation) -> some View {
        NavigationStack {
            Form {
                Section("Request") {
                    LabeledContent("Vibe", value: affiliation.club?.name ?? "Vibe")
                    LabeledContent(affiliation.entityType == .show ? "Show" : "Channel",
                                   value: affiliation.entity?.displayName ?? "Unavailable")
                }
                Section("Decision") {
                    Picker("Action", selection: $action) {
                        if affiliation.status == .pending {
                            Text("Approve").tag(AffiliationReviewAction.approve)
                            Text("Reject").tag(AffiliationReviewAction.reject)
                        } else if affiliation.status == .approved {
                            Text("Revoke").tag(AffiliationReviewAction.revoke)
                        }
                    }
                    if action == .approve {
                        Picker("Relationship", selection: $relationship) {
                            Text("Affiliated community").tag(VibeAffiliationRelationship.affiliatedCommunity)
                            Text("Official").tag(VibeAffiliationRelationship.official)
                        }
                    }
                    TextField(
                        action == .approve ? "Optional review note" : "Reason (required)",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }
            }
            .navigationTitle("Review affiliation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { selected = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit(affiliation) } }
                        .disabled(
                            busyID != nil
                            || (action != .approve && note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                        )
                }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            queue = try await api.reviewableAffiliations(status: status)
        } catch {
            queue = nil
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }

    @MainActor
    private func submit(_ affiliation: VibeAffiliation) async {
        guard busyID == nil else { return }
        busyID = affiliation.id
        do {
            _ = try await api.reviewAffiliation(
                id: affiliation.id,
                action: action,
                note: note,
                relationship: relationship
            )
            selected = nil
            await load()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        busyID = nil
    }
}

private enum VibeModerationTab: String, CaseIterable, Identifiable {
    case ripples = "Ripples"
    case reports = "Reports"
    case requests = "Requests"
    case members = "Members"
    var id: String { rawValue }
}

struct VibeModerationView: View {
    let slug: String
    let capabilities: VibeCapabilities
    @Environment(\.dismiss) private var dismiss
    @State private var tab: VibeModerationTab = .ripples
    @State private var ripples: [ModerationRipple] = []
    @State private var reports: [ModerationReport] = []
    @State private var requests: [VibePendingJoinRequest] = []
    @State private var members: [VibeMember] = []
    @State private var selectedRipple: ModerationRipple?
    @State private var selectedReport: ModerationReport?
    @State private var selectedRequest: VibePendingJoinRequest?
    @State private var selectedMember: VibeMember?
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    private var tabs: [VibeModerationTab] {
        var value: [VibeModerationTab] = []
        if capabilities.canModerateContent {
            value.append(contentsOf: [.ripples, .reports])
        }
        if capabilities.canModerateMembers {
            value.append(contentsOf: [.requests, .members])
        }
        return value
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Moderation", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(C.pagePad)

                if isLoading {
                    ProgressView().tint(C.watch).frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Vibe Moderation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if !tabs.contains(tab), let first = tabs.first { tab = first }
                await load()
            }
            .onChange(of: tab) { _, _ in Task { await load() } }
            .sheet(item: $selectedRipple) { ripple in
                RippleModerationDecisionSheet(ripple: ripple) {
                    selectedRipple = nil
                    await load()
                }
            }
            .sheet(item: $selectedReport) { report in
                ReportResolutionSheet(slug: slug, report: report) {
                    selectedReport = nil
                    await load()
                }
            }
            .sheet(item: $selectedRequest) { request in
                JoinRequestDecisionSheet(slug: slug, request: request) {
                    selectedRequest = nil
                    await load()
                }
            }
            .sheet(item: $selectedMember) { member in
                MemberModerationSheet(
                    slug: slug,
                    member: member,
                    capabilities: capabilities
                ) {
                    selectedMember = nil
                    await load()
                }
            }
            .alert(
                "Moderation could not be loaded",
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
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                switch tab {
                case .ripples:
                    if ripples.isEmpty { empty("No Ripples need review") }
                    ForEach(ripples) { ripple in
                        moderationRow(
                            title: ripple.author.name ?? ripple.author.handle ?? "Member",
                            subtitle: ripple.body ?? "Media Ripple",
                            badge: ripple.status
                        ) { selectedRipple = ripple }
                    }
                case .reports:
                    if reports.isEmpty { empty("No open reports") }
                    ForEach(reports) { report in
                        moderationRow(
                            title: report.reason,
                            subtitle: report.details
                                ?? report.post?.body
                                ?? report.comment?.content
                                ?? report.reportedUser?.name
                                ?? report.targetType.capitalized,
                            badge: report.status
                        ) { selectedReport = report }
                    }
                case .requests:
                    if requests.isEmpty { empty("No pending join requests") }
                    ForEach(requests) { request in
                        moderationRow(
                            title: request.user.name ?? request.user.handle ?? "Westreem user",
                            subtitle: request.message ?? "Wants to join this Vibe",
                            badge: "PENDING"
                        ) { selectedRequest = request }
                    }
                case .members:
                    if members.isEmpty { empty("No active members") }
                    ForEach(members) { member in
                        moderationRow(
                            title: member.user.name ?? member.user.handle ?? "Westreem user",
                            subtitle: member.user.handle.map { "@\($0)" } ?? "Active member",
                            badge: member.role
                        ) { selectedMember = member }
                    }
                }
            }
            .padding(C.pagePad)
        }
        .refreshable { await load() }
    }

    private func empty(_ title: String) -> some View {
        ContentUnavailableView(title, systemImage: "checkmark.shield")
            .foregroundStyle(C.text)
            .padding(.top, 50)
    }

    private func moderationRow(
        title: String,
        subtitle: String,
        badge: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(C.text)
                    Text(subtitle).font(.caption).foregroundStyle(C.textMuted).lineLimit(3)
                    Text(badge.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption2.bold()).foregroundStyle(C.watch)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(C.textMuted)
            }
            .padding(12)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            switch tab {
            case .ripples:
                ripples = try await api.moderationRipples(vibeSlug: slug)
            case .reports:
                reports = try await api.moderationReports(vibeSlug: slug)
            case .requests:
                requests = try await api.joinRequests(vibeSlug: slug)
            case .members:
                members = try await api.vibeMembers(vibeSlug: slug).members
            }
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        isLoading = false
    }
}

private struct MemberModerationSheet: View {
    let slug: String
    let member: VibeMember
    let capabilities: VibeCapabilities
    let onFinished: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var role: String
    @State private var status = "ACTIVE"
    @State private var reason = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    init(
        slug: String,
        member: VibeMember,
        capabilities: VibeCapabilities,
        onFinished: @escaping () async -> Void
    ) {
        self.slug = slug
        self.member = member
        self.capabilities = capabilities
        self.onFinished = onFinished
        _role = State(initialValue: member.role)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Member") {
                    LabeledContent("Name", value: member.user.name ?? member.user.handle ?? "Westreem user")
                    LabeledContent("Current role", value: member.role.capitalized)
                }
                if capabilities.canManageRoles && member.role != "OWNER" {
                    Section("Role") {
                        Picker("Role", selection: $role) {
                            Text("Member").tag("MEMBER")
                            Text("Moderator").tag("MODERATOR")
                            Text("Administrator").tag("ADMIN")
                        }
                    }
                }
                if member.role != "OWNER" {
                    Section("Status") {
                        Picker("Action", selection: $status) {
                            Text("Keep active").tag("ACTIVE")
                            Text("Suspend").tag("SUSPENDED")
                            if capabilities.canBanMembers {
                                Text("Ban").tag("BANNED")
                            }
                            Text("Remove").tag("REMOVED")
                        }
                        if status != "ACTIVE" {
                            TextField("Moderation reason (required)", text: $reason, axis: .vertical)
                                .lineLimit(2...5)
                        }
                    }
                }
                Section {
                    Text("Only active members can be listed by the current server contract. Suspended, banned, and removed members cannot be rediscovered in this screen.")
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
            }
            .navigationTitle("Manage Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(
                            busy
                            || (status != "ACTIVE" && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        )
                }
            }
            .alert(
                "Member update failed",
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
        guard !busy else { return }
        busy = true
        do {
            _ = try await api.updateVibeMember(
                vibeSlug: slug,
                userId: member.user.id,
                role: capabilities.canManageRoles && role != member.role ? role : nil,
                status: status != "ACTIVE" ? status : nil,
                reason: reason
            )
            await onFinished()
            dismiss()
        } catch {
            errorMessage = socialErrorMessage(error)
        }
        busy = false
    }
}

private struct RippleModerationDecisionSheet: View {
    let ripple: ModerationRipple
    let onFinished: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var action = "approve"
    @State private var reason = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Form {
                Section("Ripple") {
                    Text(ripple.body ?? "Media Ripple")
                    LabeledContent("Status", value: ripple.status.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                Section("Decision") {
                    Picker("Action", selection: $action) {
                        Text("Approve").tag("approve")
                        Text("Restore").tag("restore")
                        Text("Hide").tag("hide")
                        Text("Investigate").tag("investigate")
                        Text("Remove").tag("remove")
                    }
                    if !["approve", "restore"].contains(action) {
                        TextField("Reason (required)", text: $reason, axis: .vertical)
                    }
                }
            }
            .navigationTitle("Review Ripple")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(busy || (!["approve", "restore"].contains(action) && reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 3))
                }
            }
            .alert("Moderation failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @MainActor
    private func submit() async {
        busy = true
        do {
            try await api.moderateRipple(postId: ripple.id, action: action, reason: reason)
            await onFinished()
            dismiss()
        } catch { errorMessage = socialErrorMessage(error) }
        busy = false
    }
}

private struct ReportResolutionSheet: View {
    let slug: String
    let report: ModerationReport
    let onFinished: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = "REVIEWING"
    @State private var note = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Form {
                Section("Report") {
                    Text(report.reason).font(.headline)
                    if let details = report.details { Text(details) }
                }
                Section("Resolution") {
                    Picker("Status", selection: $status) {
                        Text("Reviewing").tag("REVIEWING")
                        Text("Resolved — actioned").tag("RESOLVED_ACTIONED")
                        Text("Resolved — no action").tag("RESOLVED_NO_ACTION")
                    }
                    TextField("Resolution note", text: $note, axis: .vertical)
                }
                if status == "RESOLVED_ACTIONED" {
                    Text("Resolve the report after separately applying the appropriate Ripple or member action.")
                        .font(.caption).foregroundStyle(C.textMuted)
                }
            }
            .navigationTitle("Resolve Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await submit() } }
                        .disabled(busy || (status.hasPrefix("RESOLVED") && note.trimmingCharacters(in: .whitespacesAndNewlines).count < 3))
                }
            }
            .alert("Report update failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @MainActor
    private func submit() async {
        busy = true
        do {
            try await api.resolveReport(vibeSlug: slug, reportId: report.id, status: status, note: note)
            await onFinished()
            dismiss()
        } catch { errorMessage = socialErrorMessage(error) }
        busy = false
    }
}

private struct JoinRequestDecisionSheet: View {
    let slug: String
    let request: VibePendingJoinRequest
    let onFinished: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    Text(request.user.name ?? request.user.handle ?? "Westreem user")
                    if let message = request.message { Text(message) }
                }
                Section("Optional note") {
                    TextField("Message to the requester", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Join Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Reject", role: .destructive) { Task { await decide(false) } }.disabled(busy)
                    Button("Approve") { Task { await decide(true) } }.disabled(busy)
                }
            }
            .alert("Decision failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @MainActor
    private func decide(_ approve: Bool) async {
        busy = true
        do {
            try await api.decideJoinRequest(vibeSlug: slug, requestId: request.id, approve: approve, note: note)
            await onFinished()
            dismiss()
        } catch { errorMessage = socialErrorMessage(error) }
        busy = false
    }
}
