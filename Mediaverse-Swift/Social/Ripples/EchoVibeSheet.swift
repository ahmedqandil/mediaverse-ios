import SwiftUI

struct EchoVibeSheet: View {
    let ripple: Ripple
    let onEchoed: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destinations: [PostableVibe] = []
    @State private var selectedSlugs = Set<String>()
    @State private var query = ""
    @State private var quote = ""
    @State private var isQuoteEcho = false
    @State private var isLoading = true
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private let api = LegacySocialAPIAdapter(transport: APIClient.shared)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview

                    if isLoading {
                        ProgressView("Loading destinations…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        destinationPicker
                        echoMode
                        publishButton
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("echo-error")
                    }
                    if let successMessage {
                        Text(successMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("echo-success")
                    }
                }
                .padding(16)
            }
            .background(C.bg)
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .task { await loadDestinations() }
    }

    private var preview: some View {
        HStack(spacing: 12) {
            SocialIdentityAvatar(
                image: ripple.author.image,
                name: ripple.author.name ?? ripple.author.handle,
                size: 52
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("RIPPLE")
                    .font(.caption2.bold())
                    .foregroundStyle(C.watch)
                Text(ripple.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                     ? ripple.body!
                     : "Ripple by \(ripple.author.name ?? ripple.author.handle ?? "Westreem user")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.text)
                    .lineLimit(3)
                if let club = ripple.club {
                    Text(club.name)
                        .font(.caption)
                        .foregroundStyle(C.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(C.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Content being Echoed")
    }

    @ViewBuilder
    private var destinationPicker: some View {
        if let personal = destinations.first(where: \.isPersonal) {
            destinationRow(personal, subtitle: "Echo directly to My Pulse")
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Find a Vibe")
                .font(.caption.bold())
                .foregroundStyle(C.textMuted)
            TextField("Search by Vibe name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(C.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Vibes appear after you start typing.")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if matchingVibes.isEmpty {
                Text("No matching Vibes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(matchingVibes) { vibe in
                    destinationRow(vibe, subtitle: nil)
                }
            }
        }

        if !selectedSlugs.isEmpty {
            HStack {
                Text("\(selectedSlugs.count) destination\(selectedSlugs.count == 1 ? "" : "s") selected")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Clear") { selectedSlugs.removeAll() }
                    .font(.caption.bold())
            }
            .foregroundStyle(C.watch)
        }
    }

    private var echoMode: some View {
        VStack(spacing: 10) {
            Picker("Echo mode", selection: $isQuoteEcho) {
                Text("Echo").tag(false)
                Text("Quote Echo").tag(true)
            }
            .pickerStyle(.segmented)

            if isQuoteEcho {
                TextField("Add your take…", text: $quote, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(12)
                    .background(C.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var publishButton: some View {
        Button {
            Task { await publish() }
        } label: {
            Label(
                isPublishing
                    ? "Echoing…"
                    : "Echo\(selectedSlugs.count > 1 ? " to \(selectedSlugs.count)" : "")",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(C.watch)
        .disabled(selectedSlugs.isEmpty || isPublishing)
    }

    private var matchingVibes: [PostableVibe] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return destinations.filter {
            !$0.isPersonal && "\($0.name) \($0.slug)".lowercased().contains(normalized)
        }
    }

    private func destinationRow(_ vibe: PostableVibe, subtitle: String?) -> some View {
        Button {
            if selectedSlugs.contains(vibe.slug) {
                selectedSlugs.remove(vibe.slug)
            } else {
                selectedSlugs.insert(vibe.slug)
            }
            errorMessage = nil
            successMessage = nil
        } label: {
            HStack(spacing: 10) {
                SocialIdentityAvatar(image: vibe.avatarURL, name: vibe.name, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.isPersonal ? "My Pulse" : vibe.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(C.textMuted)
                    }
                }
                Spacer()
                Image(systemName: selectedSlugs.contains(vibe.slug) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selectedSlugs.contains(vibe.slug) ? C.watch : C.textMuted)
            }
            .padding(10)
            .background(C.surface)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.borderSubtle))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadDestinations() async {
        isLoading = true
        errorMessage = nil
        do {
            _ = try await api.ensurePersonalVibe()
            destinations = try await api.postableVibes()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func publish() async {
        guard !selectedSlugs.isEmpty, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        successMessage = nil
        let slugs = selectedSlugs.sorted()
        var completed = 0
        var pending = 0
        var failures: [String] = []

        await withTaskGroup(of: (String, Result<Ripple, Error>).self) { group in
            for slug in slugs {
                group.addTask {
                    do {
                        let created = try await api.createRipple(
                            inVibe: slug,
                            body: isQuoteEcho ? quote : nil,
                            attachments: [.ripple(id: ripple.id)]
                        )
                        return (slug, .success(created))
                    } catch {
                        return (slug, .failure(error))
                    }
                }
            }
            for await (slug, result) in group {
                switch result {
                case .success(let created):
                    completed += 1
                    if created.status == "PENDING_REVIEW" { pending += 1 }
                case .failure:
                    failures.append(slug)
                }
            }
        }

        isPublishing = false
        if completed > 0 {
            onEchoed(completed)
            successMessage = pending == completed
                ? "Echo\(completed == 1 ? "" : "es") submitted for moderator review."
                : "Echoed to \(completed) destination\(completed == 1 ? "" : "s")."
        }
        if failures.isEmpty {
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } else {
            selectedSlugs = Set(failures)
            errorMessage = "Could not Echo to \(failures.joined(separator: ", "))."
        }
    }
}
