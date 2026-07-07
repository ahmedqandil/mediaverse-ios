import SwiftUI

struct BackstageStoriesView: View {
    let publishers: [UploadContext]
    let onCreate: (UploadContext?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var repository = StoriesRepository()
    @State private var selectedPublisherID: String?
    @State private var storyPendingDelete: StoryItem?
    @State private var errorText: String?

    private var selectedPublisher: UploadContext? {
        guard let selectedPublisherID else { return nil }
        return publishers.first { $0.id == selectedPublisherID }
    }

    private var managedGroups: [StoryGroup] {
        repository.groups.filter { group in
            publishers.contains { publisher in
                publisher.id == group.publisherId && publisher.type == group.publisherType
            }
        }
    }

    private var visibleGroups: [StoryGroup] {
        guard let selectedPublisherID else { return managedGroups }
        return managedGroups.filter { $0.publisherId == selectedPublisherID }
    }

    private var activeStoryCount: Int {
        visibleGroups.reduce(0) { $0 + $1.stories.count }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                C.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    publisherFilter
                    headerRow
                    content
                }
                .padding(C.pagePad)
            }
            .navigationTitle("Stories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(C.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCreate(selectedPublisher)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(C.watch)
                    .disabled(publishers.isEmpty)
                    .accessibilityLabel("Create story")
                }
            }
        }
        .task { await repository.refresh(force: true) }
        .alert("Delete story?", isPresented: Binding(
            get: { storyPendingDelete != nil },
            set: { if !$0 { storyPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let story = storyPendingDelete else { return }
                Task { await delete(story) }
            }
            Button("Cancel", role: .cancel) { storyPendingDelete = nil }
        } message: {
            Text("This removes the story immediately for every viewer.")
        }
    }

    private var publisherFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", selected: selectedPublisherID == nil) {
                    selectedPublisherID = nil
                }
                ForEach(publishers) { publisher in
                    filterChip(title: publisher.name, selected: selectedPublisherID == publisher.id) {
                        selectedPublisherID = publisher.id
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Active stories")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(C.text)
                Text("\(activeStoryCount) live · expires automatically after 24 h")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textTertiary)
            }
            Spacer()
            Button {
                Task { await repository.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .tint(C.watch)
            .accessibilityLabel("Refresh stories")
        }
    }

    @ViewBuilder
    private var content: some View {
        if repository.isLoading && repository.groups.isEmpty {
            ProgressView()
                .tint(C.watch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleGroups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "circle.dashed.inset.filled")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(C.watch)
                Text("No active stories")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(C.text)
                Button {
                    onCreate(selectedPublisher)
                } label: {
                    Label("Create Story", systemImage: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(C.watch)
                .disabled(publishers.isEmpty)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    ForEach(visibleGroups) { group in
                        ForEach(group.stories) { story in
                            storyRow(story: story, group: group)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func storyRow(story: StoryItem, group: StoryGroup) -> some View {
        HStack(spacing: 12) {
            StoryBackstageThumbnail(story: story)
                .frame(width: 58, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(group.publisherName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(C.text)
                        .lineLimit(1)
                    Text(story.mediaType.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(story.mediaType == "video" ? C.play : C.watch)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((story.mediaType == "video" ? C.play : C.watch).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                if let caption = story.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(2)
                } else {
                    Text("No caption")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textTertiary)
                }

                Text("\(story.viewCount) views · \(timeRemaining(until: story.expiresAt)) left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(C.textTertiary)
            }

            Spacer()

            Button(role: .destructive) {
                storyPendingDelete = story
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("Delete story")
        }
        .padding(10)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.borderSubtle, lineWidth: 1))
    }

    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? .black : C.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? C.watch : C.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func delete(_ story: StoryItem) async {
        do {
            try await repository.deleteStory(id: story.id)
            storyPendingDelete = nil
            errorText = nil
            NotificationCenter.default.post(name: .storiesDidChange, object: nil)
        } catch {
            errorText = error.localizedDescription
            storyPendingDelete = nil
        }
    }

    private func timeRemaining(until date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }
}

private struct StoryBackstageThumbnail: View {
    let story: StoryItem

    var body: some View {
        ZStack {
            if story.mediaType.lowercased() == "image", let url = C.mediaURL(story.mediaUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        C.elevated
                    }
                }
            } else {
                C.elevated.overlay {
                    Image(systemName: story.mediaType.lowercased() == "video" ? "play.fill" : "photo")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(C.watch)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(story.duration)s")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(5)
        }
    }
}
