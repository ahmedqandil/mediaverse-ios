import SwiftUI

struct ViewerCountChip: View {
    let viewCount: Int
    let previewAvatars: [ViewerUser]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if !previewAvatars.isEmpty {
                    ZStack(alignment: .leading) {
                        ForEach(Array(previewAvatars.prefix(3).enumerated()), id: \.offset) { index, viewer in
                            ViewerAvatarView(user: viewer, size: 24)
                                .offset(x: CGFloat(index) * 16)
                                .zIndex(Double(3 - index))
                        }
                    }
                    .frame(width: previewAvatarWidth, height: 24)
                }

                Text("\(viewCount) viewer\(viewCount == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show flash viewers")
    }

    private var previewAvatarWidth: CGFloat {
        let count = min(previewAvatars.count, 3)
        guard count > 0 else { return 0 }
        return CGFloat(16 * (count - 1)) + 28
    }
}

struct ViewerAvatarView: View {
    let user: ViewerUser
    let size: CGFloat

    var body: some View {
        Group {
            if let image = user.image, let url = C.mediaURL(image) {
                CachedRemoteImage(
                    url: url,
                    targetSize: CGSize(width: size, height: size)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    placeholderCircle
                }
            } else {
                placeholderCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5))
    }

    private var placeholderCircle: some View {
        Circle()
            .fill(C.watch.opacity(0.9))
            .overlay {
                Text(String((user.name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.black)
            }
    }
}
