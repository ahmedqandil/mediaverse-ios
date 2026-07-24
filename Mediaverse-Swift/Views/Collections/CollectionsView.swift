import SwiftUI

/// User collections list + create modal.
/// Mirrors /src/app/collections/page.tsx
struct CollectionsView: View {

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var platformConfig: PlatformConfigManager

    @State private var collections   = [Collection]()
    @State private var publicCollections = [Collection]()
    @State private var isLoading     = true
    @State private var showCreate    = false
    @State private var activeTab: CollectionTab = .mine
    @State private var deletingId: String?
    @State private var followingCollectionIds = Set<String>()
    @State private var togglingCollectionId: String?
    private var pageConfig: PlatformBrowseItem { platformConfig.browseItem(id: "collections") }

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

            if !pageConfig.enabled {
                PlatformSectionUnavailableView(item: pageConfig)
            } else if !auth.isAuthenticated {
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if pageConfig.enabled && auth.isAuthenticated {
                    Button {
                        C.lightHaptic()
                        showCreate = true
                    } label: {
                        MediaverseIcon(name: "folder", fallbackSystemName: "folder.badge.plus")
                            .frame(width: 21, height: 21)
                            .foregroundStyle(C.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create collection")
                }
            }
        }
        .task {
            guard pageConfig.enabled else { isLoading = false; return }
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
        MediaverseUnderlineTabStrip(
            items: CollectionTab.allCases.map { MediaverseTabItem(id: $0.id, label: $0.label) },
            selectedID: activeTab.id,
            fillsWidth: false
        ) { id in
            guard let tab = CollectionTab.allCases.first(where: { $0.id == id }) else { return }
            activeTab = tab
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
        .refreshable {
            C.lightHaptic()
            await load()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            MediaverseIcon(name: "library", fallbackSystemName: "square.stack")
                .frame(width: 40, height: 40)
                .foregroundStyle(C.textMuted)
            Text("No collections yet")
                .font(.headline).foregroundStyle(C.text)
            Text("Organize your favourite shows and videos")
                .font(.subheadline).foregroundStyle(C.textMuted)
                .multilineTextAlignment(.center)
            Button {
                C.lightHaptic()
                showCreate = true
            } label: {
                HStack(spacing: 8) {
                    MediaverseIcon(name: "folder", fallbackSystemName: "folder.badge.plus")
                        .frame(width: 15, height: 15)
                    Text("Create collection")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(C.watch)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
            MediaverseIcon(name: "library", fallbackSystemName: "square.stack")
                .frame(width: 40, height: 40)
                .foregroundStyle(C.textMuted)
            Text("Sign in to see your collections")
                .font(.headline).foregroundStyle(C.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = collections.isEmpty && publicCollections.isEmpty
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
        let aspectRatio = C.mediaAspectRatio(forContentType: type)

        if thumbs.count >= 4 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    thumb(thumbs[i])
                        .aspectRatio(aspectRatio, contentMode: .fit)
                }
            }
        } else if let url = thumbs.first.flatMap({ $0 }) {
            CachedRemoteImage(
                url: C.mediaURL(url),
                targetSize: CGSize(width: 220, height: 220 / max(aspectRatio, 0.01))
            ) { img in
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
            CachedRemoteImage(
                url: C.mediaURL(url),
                targetSize: CGSize(width: 120, height: 120)
            ) { img in
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

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        collectionTextField(
                            title: "Title",
                            placeholder: "My Collection",
                            text: $title
                        )

                        collectionTextField(
                            title: "Description (optional)",
                            placeholder: "What's this collection about?",
                            text: $description
                        )

                        segmentedSection(title: "Type", options: types, selection: $type)
                        segmentedSection(
                            title: "Visibility",
                            options: [("private", "Private"), ("public", "Public")],
                            selection: $visibility
                        )

                        if let err = errorMsg {
                            Text(err)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        C.lightHaptic()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(C.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(C.elevated.opacity(0.90), in: Capsule())
                            .overlay { Capsule().stroke(C.border, lineWidth: 1) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        C.lightHaptic()
                        _ = Task<Void, Never>(priority: nil) { await save() }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(.black).scaleEffect(0.72)
                            } else {
                                Text("Create")
                                    .font(.system(size: 15, weight: .bold))
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(minWidth: 78)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(canSave ? C.watch : C.watch.opacity(0.32), in: Capsule())
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private func collectionTextField(title label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(C.textMuted)

            TextField(placeholder, text: text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(C.text)
                .tint(C.watch)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(C.elevated.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(C.borderSubtle, lineWidth: 1)
                }
        }
    }

    private func segmentedSection(title label: String, options: [(String, String)], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(C.textMuted)

            HStack(spacing: 6) {
                ForEach(options, id: \.0) { value, title in
                    Button {
                        C.lightHaptic()
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selection.wrappedValue = value
                        }
                    } label: {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(selection.wrappedValue == value ? .black : C.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                selection.wrappedValue == value ? Color.white : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(C.elevated.opacity(0.88), in: Capsule())
            .overlay { Capsule().stroke(C.borderSubtle, lineWidth: 1) }
        }
    }

    private func save() async {
        guard canSave else { return }
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
