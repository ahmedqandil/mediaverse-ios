import SwiftUI

// MARK: - SaveToCollectionSheet
// Mirrors AddToCollectionModal.tsx — presented as a bottom sheet when the user taps "Save"
// in VideoWatchView's action row. Shows the user's "clips" collections with checkboxes,
// lets them toggle a video in/out of any collection, and create new collections inline.
//
// Membership is tracked locally in `memberMap` [collectionId → Bool] and count adjustments
// in `countDelta` [collectionId → Int] so the UI stays responsive while API calls run.
//
// API:
//   GET  /api/collections              → [Collection]  (items limited to 4 for mosaic)
//   POST /api/collections/[id]/items   { videoId }  → 201 item | 409 already in
//   DELETE /api/collections/[id]/items?videoId=     → { ok: true }
//   POST /api/collections              { title, type } → Collection (no _count/items)

struct SaveToCollectionSheet: View {
    let videoId: String

    // ── Data
    @State private var collections: [Collection] = []
    @State private var isLoading:   Bool         = true
    @State private var error:       String?

    // ── Optimistic state (avoids reconstructing Collection objects)
    @State private var memberMap:   [String: Bool] = [:]   // collectionId → isMember
    @State private var countDelta:  [String: Int]  = [:]   // collectionId → ±delta on _count.items

    // ── Per-row busy indicator
    @State private var busyId:      String?

    // ── Create new
    @State private var showCreate:  Bool   = false
    @State private var newTitle:    String = ""
    @State private var isCreating:  Bool   = false
    @State private var createError: String?

    @Environment(\.dismiss) private var dismiss

    // Only "clips" collections accept regular videos.
    private var clipsCollections: [Collection] {
        collections.filter { $0.type == "clips" }
    }

    private func isInCollection(_ col: Collection) -> Bool {
        memberMap[col.id] ?? false
    }

    private func displayCount(_ col: Collection) -> Int {
        max(0, col._count.items + (countDelta[col.id] ?? 0))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(C.watch)
                } else {
                    content
                }
            }
            .navigationTitle("Save to collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.watch)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadCollections() }
    }

    // MARK: - Main content

    private var content: some View {
        VStack(spacing: 0) {
            // Error banner (API errors on toggle)
            if let e = error {
                Text(e)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, C.pagePad)
                    .padding(.vertical, 8)
                    .background(C.surface)
            }

            // Collection list
            ScrollView {
                VStack(spacing: 0) {
                    if clipsCollections.isEmpty {
                        emptyState
                    } else {
                        ForEach(clipsCollections) { col in
                            collectionRow(col)
                            Divider()
                                .background(C.border)
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Create-new section (pinned at bottom)
            Divider().background(C.border)
            createSection
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundStyle(C.textMuted.opacity(0.3))
                .padding(.bottom, 4)
            Text("No clips collections yet.")
                .font(.system(size: 14))
                .foregroundStyle(C.textMuted.opacity(0.5))
            Text("Create one below.")
                .font(.system(size: 12))
                .foregroundStyle(C.textMuted.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Collection row

    private func collectionRow(_ col: Collection) -> some View {
        let inCol  = isInCollection(col)
        let isBusy = busyId == col.id
        let count  = displayCount(col)

        return Button {
            guard busyId == nil else { return }
            Task { await toggleCollection(col) }
        } label: {
            HStack(spacing: 14) {

                // Checkbox — rounded square matching web's rounded-md border style
                ZStack {
                    if inCol {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(C.watch)
                            .frame(width: 20, height: 20)
                        if isBusy {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.65)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(C.textMuted.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                        if isBusy {
                            ProgressView()
                                .tint(C.textMuted)
                                .scaleEffect(0.65)
                        }
                    }
                }
                .frame(width: 20, height: 20)

                // Name + meta
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(C.text.opacity(0.9))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(count) item\(count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(C.textMuted.opacity(0.5))
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(C.textMuted.opacity(0.3))
                        Text(col.visibility.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(C.textMuted.opacity(0.5))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, C.pagePad)
            .padding(.vertical, 12)
            .background(inCol ? C.surface : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyId != nil)
        .opacity(busyId != nil && busyId != col.id ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.15), value: inCol)
    }

    // MARK: - Create section

    private var createSection: some View {
        VStack(spacing: 0) {
            if showCreate {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Collection name…", text: $newTitle)
                            .font(.system(size: 14))
                            .foregroundStyle(C.text)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(C.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(C.border, lineWidth: 1) }
                            .onSubmit { Task { await createAndAdd() } }

                        // Create button
                        Button {
                            Task { await createAndAdd() }
                        } label: {
                            Group {
                                if isCreating {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Create")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.black)
                                }
                            }
                            .frame(width: 58, height: 36)
                            .background(
                                newTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? C.watch.opacity(0.4)
                                    : C.watch
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)

                        // Cancel
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showCreate = false }
                            newTitle    = ""
                            createError = nil
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 12))
                                .foregroundStyle(C.textMuted.opacity(0.5))
                                .frame(height: 36)
                        }
                    }

                    if let ce = createError {
                        Text(ce)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, C.pagePad)
                .padding(.vertical, 12)
            } else {
                // "+ New collection" trigger button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showCreate = true }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                        Text("New collection")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(C.textMuted.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, C.pagePad)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data loading

    private func loadCollections() async {
        isLoading = true
        error     = nil
        do {
            let cols = try await APIClient.shared.fetchCollections()
            collections = cols
            // Build initial membership map.
            // items is limited to the first 4 by the API; if a video is beyond position 4
            // it won't be detected — same limitation as the web modal.
            memberMap  = [:]
            countDelta = [:]
            for col in cols {
                memberMap[col.id] = col.items.contains(where: {
                    $0.videoId == videoId || $0.video?.id == videoId
                })
            }
        } catch {
            self.error = "Failed to load collections"
        }
        isLoading = false
    }

    // MARK: - Toggle

    private func toggleCollection(_ col: Collection) async {
        let wasIn = isInCollection(col)
        busyId    = col.id
        error     = nil

        do {
            if wasIn {
                try await APIClient.shared.removeVideoFromCollection(collectionId: col.id, videoId: videoId)
                memberMap[col.id]  = false
                countDelta[col.id] = (countDelta[col.id] ?? 0) - 1
            } else {
                try await APIClient.shared.addVideoToCollection(collectionId: col.id, videoId: videoId)
                memberMap[col.id]  = true
                countDelta[col.id] = (countDelta[col.id] ?? 0) + 1
            }
        } catch APIError.http(409) {
            // 409 = already in collection — treat as a successful add
            memberMap[col.id] = true
        } catch {
            self.error = "Failed to update collection"
        }
        busyId = nil
    }

    // MARK: - Create + add

    private func createAndAdd() async {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !isCreating else { return }
        isCreating  = true
        createError = nil

        do {
            // 1. Create the collection
            let newCol = try await APIClient.shared.createCollection(
                title:       title,
                description: nil,
                type:        "clips",
                visibility:  "private"
            )
            // 2. Add the current video to it
            try await APIClient.shared.addVideoToCollection(collectionId: newCol.id, videoId: videoId)

            newTitle = ""
            withAnimation(.easeInOut(duration: 0.15)) { showCreate = false }

            // 3. Reload so the new collection appears with correct _count and items
            await loadCollections()
        } catch {
            createError = "Failed to create collection"
        }
        isCreating = false
    }
}
