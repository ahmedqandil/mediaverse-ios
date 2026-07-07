import CoreGraphics
import CoreMedia
import Foundation

let projectTimeScale: CMTimeScale = 600
let storyMaxDurationSeconds: Double = 60

struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var canvas: CanvasSpec
    var tracks: Tracks
    var coverTimeSeconds: Double
    var schemaVersion: Int
    var storyDestination: StoryDestination?

    static func storyDraft(title: String, destination: StoryDestination?) -> Project {
        let now = Date()
        return Project(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            canvas: .storyDefault,
            tracks: Tracks(videoClips: [], audioClips: [], overlays: []),
            coverTimeSeconds: 0,
            schemaVersion: 1,
            storyDestination: destination
        )
    }

    var totalDuration: CMTime {
        tracks.videoClips.reduce(.zero) { partial, clip in
            partial + clip.timelineDuration
        }
    }

    var totalDurationSeconds: Double {
        totalDuration.seconds
    }

    mutating func addStoryClip(_ clip: VideoClip) throws {
        let proposedDuration = totalDuration + clip.timelineDuration
        if storyDestination != nil, proposedDuration.seconds > storyMaxDurationSeconds {
            throw ProjectModelError.storyDurationLimitExceeded
        }
        tracks.videoClips.append(clip)
        updatedAt = Date()
    }
}

struct StoryDestination: Codable, Equatable {
    var publisherType: String
    var publisherId: String
}

struct CanvasSpec: Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var backgroundColor: RGBAColor

    static let storyDefault = CanvasSpec(
        width: 1080,
        height: 1920,
        fps: 30,
        backgroundColor: RGBAColor(r: 0, g: 0, b: 0, a: 1)
    )
}

struct Tracks: Codable, Equatable {
    var videoClips: [VideoClip]
    var audioClips: [AudioClip]
    var overlays: [Overlay]
}

struct VideoClip: Codable, Identifiable, Equatable {
    let id: UUID
    var assetRef: AssetRef
    var sourceStart: CMTimeValueBox
    var sourceDuration: CMTimeValueBox
    var speed: Double
    var reversed: Bool
    var volume: Float
    var muted: Bool
    var transform: Transform2D
    var cropRect: NormalizedRect?
    var filterId: String?
    var filterIntensity: Float
    var adjustments: ColorAdjust
    var transitionIn: Transition?

    var sourceStartSeconds: Double {
        get { sourceStart.time.seconds }
        set { sourceStart = CMTimeValueBox(seconds: newValue) }
    }

    var sourceDurationSeconds: Double {
        get { sourceDuration.time.seconds }
        set { sourceDuration = CMTimeValueBox(seconds: newValue) }
    }

    var timelineDuration: CMTime {
        let safeSpeed = max(speed, 0.01)
        return CMTimeMultiplyByFloat64(sourceDuration.time, multiplier: 1 / safeSpeed)
    }

    static func storyClip(assetRef: AssetRef, durationSeconds: Double) -> VideoClip {
        VideoClip(
            id: UUID(),
            assetRef: assetRef,
            sourceStart: CMTimeValueBox(seconds: 0),
            sourceDuration: CMTimeValueBox(seconds: durationSeconds),
            speed: 1,
            reversed: false,
            volume: assetRef.kind == .image ? 0 : 1,
            muted: assetRef.kind == .image,
            transform: .identity,
            cropRect: nil,
            filterId: nil,
            filterIntensity: 1,
            adjustments: .neutral,
            transitionIn: nil
        )
    }
}

struct AudioClip: Codable, Identifiable, Equatable {
    let id: UUID
    var assetRef: AssetRef
    var startOnTimeline: CMTimeValueBox
    var sourceStart: CMTimeValueBox
    var duration: CMTimeValueBox
    var volume: Float
    var fadeIn: CMTimeValueBox
    var fadeOut: CMTimeValueBox
}

enum Overlay: Codable, Identifiable, Equatable {
    case text(TextOverlay)
    case sticker(StickerOverlay)
    case drawing(DrawingOverlay)
    case link(LinkOverlay)
    case interactive(StoryInteractiveOverlay)

    var id: UUID {
        switch self {
        case .text(let overlay): return overlay.id
        case .sticker(let overlay): return overlay.id
        case .drawing(let overlay): return overlay.id
        case .link(let overlay): return overlay.id
        case .interactive(let overlay): return overlay.id
        }
    }
}

struct TextOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var transform: Transform2D
    var timeRange: TimelineRange
    var style: TextOverlayStyle

    init(
        id: UUID = UUID(),
        text: String,
        transform: Transform2D,
        timeRange: TimelineRange,
        style: TextOverlayStyle = .default
    ) {
        self.id = id
        self.text = text
        self.transform = transform
        self.timeRange = timeRange
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case transform
        case timeRange
        case style
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        transform = try container.decode(Transform2D.self, forKey: .transform)
        timeRange = try container.decode(TimelineRange.self, forKey: .timeRange)
        style = try container.decodeIfPresent(TextOverlayStyle.self, forKey: .style) ?? .default
    }
}

struct TextOverlayStyle: Codable, Equatable {
    var fontSize: Double
    var fontName: String?
    var color: RGBAColor
    var backgroundColor: RGBAColor?
    var alignment: String
    var shadow: Bool

    static let `default` = TextOverlayStyle(
        fontSize: 56,
        fontName: nil,
        color: RGBAColor(r: 1, g: 1, b: 1, a: 1),
        backgroundColor: RGBAColor(r: 0, g: 0, b: 0, a: 0.42),
        alignment: "center",
        shadow: true
    )
}

struct StickerOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var assetRef: AssetRef?
    var emoji: String?
    var transform: Transform2D
    var timeRange: TimelineRange
}

struct DrawingOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var assetRef: AssetRef
    var transform: Transform2D
    var timeRange: TimelineRange
}

struct LinkOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var url: String
    var transform: Transform2D
    var timeRange: TimelineRange

    init(
        id: UUID = UUID(),
        label: String,
        url: String,
        transform: Transform2D,
        timeRange: TimelineRange
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.transform = transform
        self.timeRange = timeRange
    }
}

enum StoryInteractiveStickerKind: String, Codable, Equatable {
    case location
    case mention
    case addYours
    case poll
    case quiz
    case question
    case countdown
    case avatar
}

struct StoryInteractiveOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: StoryInteractiveStickerKind
    var title: String
    var subtitle: String?
    var options: [String]
    var targetDate: Date?
    var transform: Transform2D
    var timeRange: TimelineRange

    init(
        id: UUID = UUID(),
        kind: StoryInteractiveStickerKind,
        title: String,
        subtitle: String? = nil,
        options: [String] = [],
        targetDate: Date? = nil,
        transform: Transform2D,
        timeRange: TimelineRange
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self.targetDate = targetDate
        self.transform = transform
        self.timeRange = timeRange
    }
}

struct AssetRef: Codable, Equatable {
    let id: UUID
    var kind: AssetKind
    var relativePath: String
    var localIdentifier: String?
    var naturalWidth: Int
    var naturalHeight: Int
    var nominalFrameRate: Float
    var duration: CMTimeValueBox
    var preferredTransform: [Double]

    var durationSeconds: Double {
        get { duration.time.seconds }
        set { duration = CMTimeValueBox(seconds: newValue) }
    }
}

enum AssetKind: String, Codable, Equatable {
    case image
    case video
    case audio
}

struct Transform2D: Codable, Equatable {
    var scale: Double
    var rotation: Double
    var tx: Double
    var ty: Double

    static let identity = Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0)
}

struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct RGBAColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

struct ColorAdjust: Codable, Equatable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var warmth: Float
    var vignette: Float

    static let neutral = ColorAdjust(brightness: 0, contrast: 1, saturation: 1, warmth: 0, vignette: 0)
}

struct Transition: Codable, Equatable {
    var id: String
    var duration: CMTimeValueBox
}

struct TimelineRange: Codable, Equatable {
    var start: CMTimeValueBox
    var duration: CMTimeValueBox
}

struct CMTimeValueBox: Codable, Equatable {
    var value: Int64
    var timescale: Int32

    init(time: CMTime) {
        let converted = time.convertScale(projectTimeScale, method: .default)
        self.value = converted.value
        self.timescale = converted.timescale
    }

    init(seconds: Double) {
        self.init(time: CMTime(seconds: seconds, preferredTimescale: projectTimeScale))
    }

    var time: CMTime {
        CMTime(value: value, timescale: timescale)
    }
}

enum ProjectModelError: LocalizedError {
    case storyDurationLimitExceeded

    var errorDescription: String? {
        switch self {
        case .storyDurationLimitExceeded:
            return "Stories can be up to 60 seconds."
        }
    }
}

private extension CGAffineTransform {
    var projectArray: [Double] {
        [a, b, c, d, tx, ty].map(Double.init)
    }
}

extension AssetRef {
    static func make(
        kind: AssetKind,
        relativePath: String,
        naturalWidth: Int,
        naturalHeight: Int,
        nominalFrameRate: Float,
        durationSeconds: Double,
        preferredTransform: CGAffineTransform = .identity,
        localIdentifier: String? = nil
    ) -> AssetRef {
        AssetRef(
            id: UUID(),
            kind: kind,
            relativePath: relativePath,
            localIdentifier: localIdentifier,
            naturalWidth: naturalWidth,
            naturalHeight: naturalHeight,
            nominalFrameRate: nominalFrameRate,
            duration: CMTimeValueBox(seconds: durationSeconds),
            preferredTransform: preferredTransform.projectArray
        )
    }
}
