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
