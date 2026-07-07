import SwiftUI

/// User collections list + create modal.
/// Mirrors /src/app/collections/page.tsx
struct CollectionsView: View {

    @EnvironmentObject private var auth: AuthManager

    @State private var collections   = [Collection]()
    @State private var publicCollections = [Collection]()
    @State private var isLoading     = true
    @State private var showCreate    = false
    @State private var activeTab: CollectionTab = .mine
    @State private var deletingId: String?
    @State private var followingCollectionIds = Set<String>()
    @State private var togglingCollectionId: String?

    private enum CollectionTab: String, CaseIterable, Identifiable {
        case mine, communities
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mine: return "My Collections"
            case .communities: return "Communities"
            }
        }
    }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if !auth.isAuthenticated {
                unauthState
            } else if isLoading {
                ProgressView().tint(C.watch)
            } else {
                VStack(spacing: 0) {
                    tabBar
                    if activeTab == .mine {
                        if collections.isEmpty {
                            emptyState
                        } else {
                            collectionGrid(collections, isOwner: true)
                        }
                    } else {
                        if publicCollections.isEmpty {
                            communitiesEmptyState
                        } else {
                            collectionGrid(publicCollections, isOwner: false)
                        }
                    }
                }
            }
        }
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if auth.isAuthenticated {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(C.text)
                    }
                }
            }
        }
        .task {
            guard auth.isAuthenticated else { isLoading = false; return }
            await load()
        }
        .sheet(isPresented: $showCreate) {
            CreateCollectionSheet { newCol in
                collections.insert(newCol, at: 0)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(CollectionTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(activeTab == tab ? C.text : C.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            if activeTab == tab {
                                Rectangle()
                                    .fill(C.watch)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, C.pagePad)
        .background(C.bg)
        .overlay(alignment: .bottom) {
            Divider().background(C.border)
        }
    }

    private func collectionGrid(_ items: [Collection], isOwner: Bool) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(items) { col in
                    CollectionCard(
                        col: col,
                        isOwner: isOwner,
                        isFollowing: followingCollectionIds.contains(col.id),
                        isTogglingFollow: togglingCollectionId == col.id,
                        onFollow: !isOwner && col.visibility == "public" ? {
                            _ = Task<Void, Never>(priority: nil) { await toggleFollow(col) }
                        } : nil,
                        onDelete: isOwner ? { _ = Task<Void, Never>(priority: nil) { await delete(col) } } : nil
                    )
                }
            }
            .padding(C.pagePad)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("No collections yet")
                .font(.headline).foregroundStyle(C.text)
            Text("Organize your favourite shows and videos")
                .font(.subheadline).foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button("Create collection") { showCreate = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(C.watch)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var communitiesEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("No public communities yet")
                .font(.headline).foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var unauthState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack")
                .font(.system(size: 40))
                .foregroundStyle(C.textMuted)
            Text("Sign in to see your collections")
                .font(.headline).foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        async let mineTask = APIClient.shared.fetchCollections()
        async let publicTask = APIClient.shared.fetchPublicCollections()
        collections = (try? await mineTask) ?? []
        publicCollections = (try? await publicTask) ?? []
        followingCollectionIds = Set(publicCollections.filter { $0.isFollowing }.map(\.id))
        isLoading = false
    }

    private func toggleFollow(_ col: Collection) async {
        guard togglingCollectionId == nil else { return }
        togglingCollectionId = col.id
        let wasFollowing = followingCollectionIds.contains(col.id)
        if wasFollowing {
            followingCollectionIds.remove(col.id)
        } else {
            followingCollectionIds.insert(col.id)
        }
        do {
            let result = try await APIClient.shared.toggleCollectionFollow(id: col.id)
            if result.following {
                followingCollectionIds.insert(col.id)
            } else {
                followingCollectionIds.remove(col.id)
            }
        } catch {
            if wasFollowing {
                followingCollectionIds.insert(col.id)
            } else {
                followingCollectionIds.remove(col.id)
            }
        }
        togglingCollectionId = nil
    }

    private func delete(_ col: Collection) async {
        guard deletingId == nil else { return }
        deletingId = col.id
        let old = collections
        collections.removeAll { $0.id == col.id }
        do {
            try await APIClient.shared.deleteCollection(id: col.id)
        } catch {
            collections = old
        }
        deletingId = nil
    }
}

// MARK: - Collection card (mosaic thumbnail)

private struct CollectionCard: View {
    let col: Collection
    let isOwner: Bool
    let isFollowing: Bool
    let isTogglingFollow: Bool
    let onFollow: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: AppRoute.collection(col.id)) {
                MosaicThumbnail(items: col.items, type: col.type)
                    .clipShape(RoundedRectangle(cornerRadius: C.cardRadius))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 7) {
                NavigationLink(value: AppRoute.collection(col.id)) {
                    Text(col.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let desc = col.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(typeLabel(col.type)) · \(col._count.items) \(col._count.items == 1 ? "item" : "items")")
                    if col.visibility == "public", col._count.followers > 0 {
                        Text("\(col._count.followers) followers")
                    }
                    if !isOwner, let userName = col.user?.name {
                        Text("by \(userName)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(C.textMuted)

                HStack(spacing: 8) {
                    Text(col.visibility == "public" ? "Public" : "Private")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(col.visibility == "public" ? C.watch : C.textMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(col.visibility == "public" ? C.watch.opacity(0.15) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    Spacer(minLength: 0)

                    if let onFollow {
                        Button(action: onFollow) {
                            Text(isFollowing ? "Following" : "Follow")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(isFollowing ? C.text : .black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isFollowing ? C.surfaceAlt : C.watch)
                                .clipShape(Capsule())
                                .overlay {
                                    if isFollowing {
                                        Capsule().stroke(C.border, lineWidth: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isTogglingFollow)
                        .opacity(isTogglingFollow ? 0.55 : 1)
                    } else if isOwner, let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.red.opacity(0.85))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.borderSubtle, lineWidth: 1) }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "shows": return "Shows"
        case "shorts": return "Shorts"
        default: return "Clips"
        }
    }
}

private struct MosaicThumbnail: View {
    let items: [CollectionItemPreview]
    let type: String

    var body: some View {
        let thumbs = items.prefix(4).map { item -> String? in
            item.show?.coverUrl ?? item.video?.thumbnailUrl
        }
        let isShows = type == "shows"
        let aspectRatio: CGFloat = isShows ? 2/3 : (type == "shorts" ? 9/16 : 16/9)

        if thumbs.count >= 4 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    thumb(thumbs[i])
                        .aspectRatio(aspectRatio, contentMode: .fit)
                }
            }
        } else if let url = thumbs.first.flatMap({ $0 }) {
            AsyncImage(url: C.mediaURL(url)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "square.stack")
                    .font(.title)
                    .foregroundStyle(Color.white.opacity(0.2))
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
        }
    }

    @ViewBuilder
    private func thumb(_ url: String?) -> some View {
        if let url {
            AsyncImage(url: C.mediaURL(url)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.white.opacity(0.04)
        }
    }
}

// MARK: - Create sheet

private struct CreateCollectionSheet: View {
    let onCreated: (Collection) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title      = ""
    @State private var description = ""
    @State private var type       = "shows"
    @State private var visibility = "private"
    @State private var isSaving   = false
    @State private var errorMsg: String?

    private let types = [("shows", "Shows"), ("clips", "Videos"), ("shorts", "Shorts")]

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                Form {
                    Section("Title") {
                        TextField("My Collection", text: $title)
                            .foregroundStyle(C.text)
                    }
                    .listRowBackground(C.surface)

                    Section("Description (optional)") {
                        TextField("What's this collection about?", text: $description)
                            .foregroundStyle(C.text)
                    }
                    .listRowBackground(C.surface)

                    Section("Type") {
                        Picker("Type", selection: $type) {
                            ForEach(types, id: \.0) { val, label in
                                Text(label).tag(val)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(C.surface)

                    Section("Visibility") {
                        Picker("Visibility", selection: $visibility) {
                            Text("Private").tag("private")
                            Text("Public").tag("public")
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(C.surface)

                    if let err = errorMsg {
                        Section {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                        .listRowBackground(C.surface)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(C.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { _ = Task<Void, Never>(priority: nil) { await save() } }
                        .disabled(title.isEmpty || isSaving)
                        .foregroundStyle(C.watch)
                }
            }
        }
    }

    private func save() async {
        guard !title.isEmpty else { return }
        isSaving = true
        errorMsg = nil
        do {
            let col = try await APIClient.shared.createCollection(
                title:       title.trimmingCharacters(in: .whitespaces),
                description: description.isEmpty ? nil : description.trimmingCharacters(in: .whitespaces),
                type:        type,
                visibility:  visibility
            )
            onCreated(col)
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
        isSaving = false
    }
}
