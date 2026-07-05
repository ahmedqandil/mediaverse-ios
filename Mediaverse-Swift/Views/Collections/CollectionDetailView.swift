import SwiftUI

struct CollectionDetailView: View {
    let collectionId: String

    @State private var collection: CollectionDetail?
    @State private var loading = true
    @State private var error = false
    @State private var following = false
    @State private var togglingFollow = false

    private var isShows: Bool { collection?.type == "shows" }
    private var isShorts: Bool { collection?.type == "shorts" }

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            if loading {
                ProgressView().tint(C.watch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if error || collection == nil {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(C.textMuted)
                    Text("Collection not found or is private")
                        .font(.headline)
                        .foregroundStyle(C.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let collection {
                content(collection)
            }
        }
        .navigationTitle(collection?.title ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ col: CollectionDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(col)
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 12)

                if col.isOwner {
                    AddCollectionItemsPanel(collection: col) { item in
                        collection = collection.map { old in
                            CollectionDetail(
                                id: old.id,
                                title: old.title,
                                description: old.description,
                                type: old.type,
                                visibility: old.visibility,
                                updatedAt: old.updatedAt,
                                user: old.user,
                                _count: CollectionCount(items: old._count.items + 1, followers: old._count.followers),
                                items: old.items + [item],
                                isFollowing: old.isFollowing,
                                isOwner: old.isOwner
                            )
                        }
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 24)
                }

                if col.items.isEmpty {
                    emptyState(col)
                        .padding(.horizontal, C.pagePad)
                        .padding(.top, 28)
                } else {
                    itemGrid(col)
                        .padding(.horizontal, C.pagePad)
                        .padding(.top, 28)
                }

                if col.visibility == "public" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Community Discussion")
                            .font(.headline)
                            .foregroundStyle(C.text)
                        CommentThreadView(
                            target: .collection(col.id),
                            showsHeader: false
                        )
                    }
                    .padding(.horizontal, C.pagePad)
                    .padding(.top, 34)
                }

                Color.clear.frame(height: 44)
            }
        }
    }

    private func header(_ col: CollectionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(col.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(2)

                    if let desc = col.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(C.textMuted)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if col.visibility == "public", !col.isOwner {
                    Button {
                        Task { await toggleFollow() }
                    } label: {
                        Text(following ? "✓ Following" : "Follow")
                            .font(.subheadline.bold())
                            .foregroundStyle(following ? C.text : C.bg)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(following ? Color.white.opacity(0.12) : C.watch)
                            .clipShape(Capsule())
                            .overlay {
                                if following { Capsule().stroke(C.border, lineWidth: 1) }
                            }
                    }
                    .disabled(togglingFollow)
                }
            }

            HStack(spacing: 6) {
                Text("By \(col.user?.name ?? "Unknown")")
                Text("·")
                Text(typeLabel(col.type))
                Text("·")
                Text("\(col.items.count) \(col.items.count == 1 ? "item" : "items")")
                if col.visibility == "public" {
                    Text("·")
                    Text("\(col._count.followers) followers")
                }
                Text(visibilityBadge(col.visibility))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(col.visibility == "public" ? C.watch : C.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(col.visibility == "public" ? C.watch.opacity(0.15) : Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .font(.caption)
            .foregroundStyle(C.textMuted)
            .lineLimit(2)
        }
    }

    @ViewBuilder
    private func itemGrid(_ col: CollectionDetail) -> some View {
        let columns: [GridItem] = col.type == "clips"
            ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(col.items.enumerated()), id: \.element.id) { index, item in
                CollectionItemCard(
                    item: item,
                    index: index,
                    collectionType: col.type,
                    isOwner: col.isOwner,
                    onRemove: { Task { await remove(item) } }
                )
            }
        }
    }

    private func emptyState(_ col: CollectionDetail) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(C.textMuted)
            Text("This collection is empty.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(C.text)
            if col.isOwner {
                Text("Use the search above to add \(typeLabel(col.type).lowercased()).")
                    .font(.caption)
                    .foregroundStyle(C.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(C.borderSubtle, lineWidth: 1) }
    }

    private func load() async {
        loading = true
        error = false
        do {
            let detail = try await APIClient.shared.fetchCollectionDetail(id: collectionId)
            collection = detail
            following = detail.isFollowing
        } catch {
            self.error = true
        }
        loading = false
    }

    private func toggleFollow() async {
        guard !togglingFollow else { return }
        togglingFollow = true
        do {
            let result = try await APIClient.shared.toggleCollectionFollow(id: collectionId)
            let delta = result.following == following ? 0 : (result.following ? 1 : -1)
            following = result.following
            collection = collection.map { old in
                CollectionDetail(
                    id: old.id,
                    title: old.title,
                    description: old.description,
                    type: old.type,
                    visibility: old.visibility,
                    updatedAt: old.updatedAt,
                    user: old.user,
                    _count: CollectionCount(items: old._count.items, followers: max(old._count.followers + delta, 0)),
                    items: old.items,
                    isFollowing: result.following,
                    isOwner: old.isOwner
                )
            }
        } catch {}
        togglingFollow = false
    }

    private func remove(_ item: CollectionDetailItem) async {
        let old = collection
        collection = collection.map { current in
            CollectionDetail(
                id: current.id,
                title: current.title,
                description: current.description,
                type: current.type,
                visibility: current.visibility,
                updatedAt: current.updatedAt,
                user: current.user,
                _count: CollectionCount(items: max(current._count.items - 1, 0), followers: current._count.followers),
                items: current.items.filter { $0.id != item.id },
                isFollowing: current.isFollowing,
                isOwner: current.isOwner
            )
        }
        do {
            try await APIClient.shared.removeCollectionItem(collectionId: collectionId, item: item)
        } catch {
            collection = old
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "shows": return "Shows"
        case "shorts": return "Shorts"
        default: return "Clips"
        }
    }

    private func visibilityBadge(_ visibility: String) -> String {
        visibility == "public" ? "Community" : "Private"
    }
}

private struct CollectionItemCard: View {
    let item: CollectionDetailItem
    let index: Int
    let collectionType: String
    let isOwner: Bool
    let onRemove: () -> Void

    private var isShows: Bool { collectionType == "shows" }
    private var isShorts: Bool { collectionType == "shorts" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            routeLink

            if isOwner {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.72))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
            }
        }
    }

    @ViewBuilder
    private var routeLink: some View {
        if let show = item.show {
            NavigationLink(value: AppRoute.show(show.id)) {
                showCard(show)
            }
            .buttonStyle(.plain)
        } else if let video = item.video {
            NavigationLink(value: AppRoute.media(id: video.id, type: video.type)) {
                videoCard(video)
            }
            .buttonStyle(.plain)
        }
    }

    private func showCard(_ show: CollectionDetailShow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                positionBadge
            }

            Text(show.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)

            if let year = show.productionYear {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(C.textMuted)
            }
        }
    }

    private func videoCard(_ video: CollectionDetailVideo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: C.mediaURL(video.thumbnailUrl)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .aspectRatio(isShorts ? 9/16 : 16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()

                positionBadge

                if let duration = video.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                }
            }

            Text(video.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
        }
    }

    private var positionBadge: some View {
        Text("\(index + 1)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.65))
            .clipShape(Circle())
            .padding(5)
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

private struct AddCollectionItemsPanel: View {
    let collection: CollectionDetail
    let onAdded: (CollectionDetailItem) -> Void

    @State private var query = ""
    @State private var results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
    @State private var isSearching = false
    @State private var addingId: String?
    @State private var debounceTask: Task<Void, Never>?

    private var isShows: Bool { collection.type == "shows" }
    private var isShorts: Bool { collection.type == "shorts" }
    private var rowsCount: Int {
        isShows ? (results.shows?.count ?? 0) : filteredVideos.count
    }
    private var filteredVideos: [SearchResultVideo] {
        let videos = results.videos ?? []
        return videos.filter { video in
            guard let type = video.type else { return false }
            return isShorts ? type == "short" : type != "short"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add \(collection.type)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.textMuted)
                .tracking(1.1)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(C.textMuted)
                    TextField("Search \(collection.type) to add...", text: $query)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .foregroundStyle(C.text)
                        .onChange(of: query) { _, value in
                            debounceTask?.cancel()
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard trimmed.count >= 2 else { results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil); return }
                            debounceTask = Task {
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled else { return }
                                await search(trimmed)
                            }
                        }
                    if isSearching {
                        ProgressView().tint(C.watch)
                    }
                }
                .padding(12)

                if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, rowsCount > 0 {
                    Divider().background(C.border)
                    LazyVStack(spacing: 0) {
                        if isShows {
                            ForEach(results.shows ?? []) { show in
                                addShowRow(show)
                            }
                        } else {
                            ForEach(filteredVideos) { video in
                                addVideoRow(video)
                            }
                        }
                    }
                }
            }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1) }
        }
    }

    private func addShowRow(_ show: SearchResultShow) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: C.mediaURL(show.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 36, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.subheadline.weight(.medium)).foregroundStyle(C.text).lineLimit(1)
                if let genre = show.genre { Text(genre).font(.caption2).foregroundStyle(C.textMuted) }
            }
            Spacer()
            addButton(id: show.id) { await add(show: show) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addVideoRow(_ video: SearchResultVideo) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: C.mediaURL(video.thumbnailUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: isShorts ? 34 : 64, height: isShorts ? 54 : 36)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.subheadline.weight(.medium)).foregroundStyle(C.text).lineLimit(1)
                if let duration = video.duration { Text(formatDuration(duration)).font(.caption2).foregroundStyle(C.textMuted) }
            }
            Spacer()
            addButton(id: video.id) { await add(video: video) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addButton(id: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(addingId == id ? "..." : "Add")
                .font(.caption.bold())
                .foregroundStyle(C.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(C.watch)
                .clipShape(Capsule())
        }
        .disabled(addingId != nil)
    }

    private func search(_ query: String) async {
        isSearching = true
        do {
            results = try await APIClient.shared.search(q: query, type: isShows ? "shows" : "videos")
        } catch {
            results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
        }
        isSearching = false
    }

    private func add(show: SearchResultShow) async {
        guard addingId == nil else { return }
        addingId = show.id
        do {
            let created = try await APIClient.shared.addShowToCollection(collectionId: collection.id, showId: show.id)
            onAdded(CollectionDetailItem(
                id: created.id,
                position: created.position,
                show: CollectionDetailShow(id: show.id, title: show.title, coverUrl: show.coverUrl, genre: show.genre, productionYear: nil, _count: nil),
                video: nil
            ))
            query = ""
            results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
        } catch {}
        addingId = nil
    }

    private func add(video: SearchResultVideo) async {
        guard addingId == nil else { return }
        addingId = video.id
        do {
            let created = try await APIClient.shared.addCollectionVideo(collectionId: collection.id, videoId: video.id)
            onAdded(CollectionDetailItem(
                id: created.id,
                position: created.position,
                show: nil,
                video: CollectionDetailVideo(id: video.id, title: video.title, thumbnailUrl: video.thumbnailUrl, type: video.type ?? "video", duration: video.duration, views: video.views)
            ))
            query = ""
            results = SearchResults(channels: nil, shows: nil, episodes: nil, videos: nil)
        } catch {}
        addingId = nil
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
