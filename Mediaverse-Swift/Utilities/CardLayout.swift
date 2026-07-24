import SwiftUI

enum CarouselCardMetrics {
    static let landscapeWidth: CGFloat = 180
    static let posterWidth: CGFloat = 112
    static let channelWidth: CGFloat = 96
    static let channelAvatarSize: CGFloat = 64
    static let spacing: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let titleLineHeight: CGFloat = 16
    static let titleHeight: CGFloat = 32
    static let metaHeight: CGFloat = 14
    static let textBlockHeight: CGFloat = titleHeight + metaHeight + 2

    static func height(width: CGFloat, contentType: String) -> CGFloat {
        width / C.mediaAspectRatio(forContentType: contentType)
    }
}

struct ContinueWatchingRailCard: View {
    let title: String
    let subtitle: String?
    let thumbnailUrl: String?
    let progress: Double
    let contentType: String?
    var width: CGFloat = 160

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var mediaHeight: CGFloat {
        width / C.mediaAspectRatio(forContentType: contentType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                CachedRemoteImage(url: C.mediaURL(thumbnailUrl), targetSize: CGSize(width: width, height: mediaHeight)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    C.surface
                }
                .frame(width: width, height: mediaHeight)
                .clipped()

                GeometryReader { geo in
                    Rectangle()
                        .fill(C.watch)
                        .frame(width: geo.size.width * CGFloat(clampedProgress), height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 3)
            }
            .frame(width: width, height: mediaHeight)
            .clipShape(RoundedRectangle(cornerRadius: CarouselCardMetrics.cornerRadius))

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.text)
                .lineLimit(2)
                .frame(width: width, height: CarouselCardMetrics.titleHeight, alignment: .topLeading)

            Group {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(C.textMuted)
                        .lineLimit(1)
                } else {
                    Color.clear
                }
            }
            .frame(width: width, height: CarouselCardMetrics.metaHeight, alignment: .leading)
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

struct ProgressExploreCarousel: View {
    enum Kind {
        case shows
        case movies
        case microdramas
    }

    let items: [ProgressItem]
    let kind: Kind

    private var cardWidth: CGFloat {
        switch kind {
        case .microdramas:
            return CarouselCardMetrics.posterWidth
        case .shows, .movies:
            return 160
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.system(size: 17, weight: .bold))
                .fontDesign(.rounded)
                .foregroundStyle(C.text)
                .padding(.horizontal, C.pagePad)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CarouselCardMetrics.spacing) {
                    ForEach(items) { item in
                        if let route = route(for: item) {
                            NavigationLink(value: route) {
                                ContinueWatchingRailCard(
                                    title: item.episode?.title ?? item.video?.title ?? "Continue watching",
                                    subtitle: subtitle(for: item),
                                    thumbnailUrl: item.episode?.thumbnailUrl ?? item.video?.thumbnailUrl,
                                    progress: item.progress,
                                    contentType: contentType(for: item),
                                    width: cardWidth
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, C.pagePad)
            }
        }
    }

    private func route(for item: ProgressItem) -> AppRoute? {
        if kind == .microdramas,
           let showId = item.episode?.season?.show?.id,
           let episodeNumber = item.episode?.episodeNumber {
            return .microdramaWatchEp(showId, episodeNumber)
        }
        if let episodeId = item.episodeId ?? item.episode?.id {
            return .episode(episodeId)
        }
        if let video = item.video {
            return C.normalizedContentType(video.type) == "short"
                ? .short(video.id, showId: nil, channelId: video.channel?.id)
                : .video(video.id)
        }
        if let videoId = item.videoId {
            return .video(videoId)
        }
        return nil
    }

    private func subtitle(for item: ProgressItem) -> String? {
        if let episode = item.episode {
            let showTitle = episode.season?.show?.title
            if let seasonNumber = episode.season?.seasonNumber, let episodeNumber = episode.episodeNumber {
                return [showTitle, "S\(seasonNumber)E\(episodeNumber)"].compactMap { $0 }.joined(separator: " · ")
            }
            if let episodeNumber = episode.episodeNumber {
                return [showTitle, "Episode \(episodeNumber)"].compactMap { $0 }.joined(separator: " · ")
            }
            return showTitle
        }
        return item.video?.channel?.name
    }

    private func contentType(for item: ProgressItem) -> String {
        if item.episode != nil || item.episodeId != nil {
            switch kind {
            case .movies:
                return "video"
            case .microdramas:
                return "microdrama"
            case .shows:
                return "episode"
            }
        }
        return item.video?.type ?? "video"
    }
}

extension View {
    func fixedCardTitle(width: CGFloat? = nil, lines: Int = 3, lineHeight: CGFloat = 16) -> some View {
        self
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, height: CGFloat(lines) * lineHeight, alignment: .topLeading)
    }
}
