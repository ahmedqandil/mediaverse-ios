import SwiftUI

private extension StoryGroup {
    func withPublisherImageFallback(_ fallbackImageUrl: String?) -> StoryGroup {
        guard publisherImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let fallbackImageUrl,
              !fallbackImageUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }

        return StoryGroup(
            publisherType: publisherType,
            publisherId: publisherId,
            publisherName: publisherName,
            publisherHandle: publisherHandle,
            publisherImageUrl: fallbackImageUrl,
            stories: stories,
            hasUnseen: hasUnseen
        )
    }
}

struct StoryTrayView: View {
    @ObservedObject var repository: StoriesRepository
    let activeChannel: UploadContext?
    var title = "FLASHES"
    let onAddStory: () -> Void
    let onSelect: (StoryGroup) -> Void

    private var activeGroup: StoryGroup? {
        guard let activeChannel else { return nil }
        return repository.groups.first { group in
            group.publisherType.caseInsensitiveCompare(activeChannel.type) == .orderedSame
                && group.publisherId == activeChannel.id
        }
    }

    private var otherGroups: [StoryGroup] {
        repository.groups.filter { group in
            guard !group.stories.isEmpty else { return false }
            return group.id != activeGroup?.id
        }
    }

    private var hasVisibleContent: Bool {
        activeChannel != nil || !otherGroups.isEmpty
    }

    var body: some View {
        Group {
            if hasVisibleContent {
                VStack(alignment: .leading, spacing: 10) {
                    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalizedTitle.isEmpty {
                        Text(normalizedTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(C.textMuted)
                            .padding(.horizontal, 12)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            if let activeChannel {
                                activeChannelTile(activeChannel)
                            }

                            ForEach(otherGroups) { group in
                                StoryAvatarView(group: group)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(group)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("Flash from \(group.publisherName)")
                                    .accessibilityHint(group.hasUnseen ? "Unseen flashes" : "Seen flashes")
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
        }
        .task { await refreshWhileVisible() }
    }

    private func refreshWhileVisible() async {
        await repository.refresh(force: true)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await repository.refresh(force: true)
        }
    }

    @ViewBuilder
    private func activeChannelTile(_ channel: UploadContext) -> some View {
        if let activeGroup, !activeGroup.stories.isEmpty {
            let displayGroup = activeGroup.withPublisherImageFallback(channel.avatarUrl)
            StoryAvatarView(group: displayGroup)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(displayGroup)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Your \(channel.type) flash")
                .accessibilityHint(activeGroup.hasUnseen ? "Unseen flashes" : "Seen flashes")
        } else {
            StoryAddAvatarView(channel: channel)
                .contentShape(Rectangle())
                .onTapGesture(perform: onAddStory)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Add flash for \(channel.name)")
        }
    }
}

struct StoryAvatarView: View {
    let group: StoryGroup
    private let avatarSize: CGFloat = 78
    private let tileWidth: CGFloat = 90

    private var initial: String {
        group.publisherName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "?"
    }

    var body: some View {
        VStack(spacing: 7) {
            avatar
                .frame(width: avatarSize, height: avatarSize)
                .padding(2)
                .background(C.bg)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(group.hasUnseen ? C.watch : Color.white.opacity(0.2), lineWidth: 2)
                }
                .opacity(group.hasUnseen ? 1 : 0.6)

            Text(group.publisherName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(group.hasUnseen ? C.text : C.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(group.hasUnseen ? 1 : 0.6)
                .frame(width: tileWidth)
        }
        .frame(width: tileWidth)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = C.mediaURL(group.publisherImageUrl) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: avatarSize, height: avatarSize)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallback
            }
            .clipShape(Circle())
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Circle()
            .fill(C.elevated)
            .overlay {
                Text(initial.uppercased())
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
    }
}

private struct StoryAddAvatarView: View {
    let channel: UploadContext
    private let avatarSize: CGFloat = 78
    private let tileWidth: CGFloat = 90

    private var initial: String {
        channel.name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "+"
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                avatar
                    .frame(width: avatarSize, height: avatarSize)
                    .padding(2)
                    .background(C.bg)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    }

                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(C.watch)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(C.bg, lineWidth: 2)
                    }
            }

            Text("Add flash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(C.text)
                .lineLimit(1)
                .frame(width: tileWidth)
        }
        .frame(width: tileWidth)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = C.mediaURL(channel.avatarUrl) {
            CachedRemoteImage(
                url: url,
                targetSize: CGSize(width: avatarSize, height: avatarSize)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallback
            }
            .clipShape(Circle())
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Circle()
            .fill(C.elevated)
            .overlay {
                Text(initial.uppercased())
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(C.textMuted)
            }
    }
}
