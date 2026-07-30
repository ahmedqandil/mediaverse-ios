import SwiftUI
/// Westreem partner/Backstage review remains active and separate from
/// Matrix-authoritative community membership and moderation.
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
                    .westreemField(minHeight: 82)
                }
            }
            .westreemFormStyle()
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
