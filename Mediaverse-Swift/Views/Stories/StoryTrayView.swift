import SwiftUI

struct StoryTrayView: View {
    @ObservedObject var repository: StoriesRepository
    let onSelect: (StoryGroup) -> Void

    var body: some View {
        if !repository.isLoading && !repository.groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("STORIES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(C.textMuted)
                    .padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(repository.groups) { group in
                            Button {
                                onSelect(group)
                            } label: {
                                StoryAvatarView(group: group)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Story from \(group.publisherName)")
                            .accessibilityHint(group.hasUnseen ? "Unseen stories" : "Seen stories")
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 8)
        }
    }
}

struct StoryAvatarView: View {
    let group: StoryGroup

    private var initial: String {
        group.publisherName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "?"
    }

    var body: some View {
        VStack(spacing: 7) {
            avatar
                .frame(width: 68, height: 68)
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
                .frame(width: 80)
        }
        .frame(width: 80)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = C.mediaURL(group.publisherImageUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallback
                }
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
