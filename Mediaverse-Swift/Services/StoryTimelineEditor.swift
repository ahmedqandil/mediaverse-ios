import AVFoundation
import CoreMedia
import Foundation

struct StoryTimelineCommand {
    let before: Project
    let after: Project
    let label: String
}

@MainActor
final class StoryTimelineEditor: ObservableObject {
    @Published private(set) var project: Project
    @Published var selectedClipID: UUID?
    @Published var selectedOverlayID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [StoryTimelineCommand] = []
    private var redoStack: [StoryTimelineCommand] = []
    private let maxCommands = 50

    init(project: Project) {
        self.project = project
        self.selectedClipID = project.tracks.videoClips.first?.id
    }

    var selectedClip: VideoClip? {
        guard let selectedClipID else { return project.tracks.videoClips.first }
        return project.tracks.videoClips.first { $0.id == selectedClipID }
    }

    var selectedClipIndex: Int? {
        guard let selectedClipID else { return project.tracks.videoClips.indices.first }
        return project.tracks.videoClips.firstIndex { $0.id == selectedClipID }
    }

    var selectedTextOverlay: TextOverlay? {
        guard let selectedOverlayID else { return nil }
        return project.tracks.overlays.compactMap { overlay -> TextOverlay? in
            if case .text(let text) = overlay, text.id == selectedOverlayID { return text }
            return nil
        }.first
    }

    var selectedStickerOverlay: StickerOverlay? {
        guard let selectedOverlayID else { return nil }
        return project.tracks.overlays.compactMap { overlay -> StickerOverlay? in
            if case .sticker(let sticker) = overlay, sticker.id == selectedOverlayID { return sticker }
            return nil
        }.first
    }

    var selectedDrawingOverlay: DrawingOverlay? {
        guard let selectedOverlayID else { return nil }
        return project.tracks.overlays.compactMap { overlay -> DrawingOverlay? in
            if case .drawing(let drawing) = overlay, drawing.id == selectedOverlayID { return drawing }
            return nil
        }.first
    }

    var selectedLinkOverlay: LinkOverlay? {
        guard let selectedOverlayID else { return nil }
        return project.tracks.overlays.compactMap { overlay -> LinkOverlay? in
            if case .link(let link) = overlay, link.id == selectedOverlayID { return link }
            return nil
        }.first
    }

    var selectedInteractiveOverlay: StoryInteractiveOverlay? {
        guard let selectedOverlayID else { return nil }
        return project.tracks.overlays.compactMap { overlay -> StoryInteractiveOverlay? in
            if case .interactive(let interactive) = overlay, interactive.id == selectedOverlayID { return interactive }
            return nil
        }.first
    }

    var selectedOverlayLabel: String? {
        guard let selectedOverlayID else { return nil }
        for overlay in project.tracks.overlays where overlay.id == selectedOverlayID {
            switch overlay {
            case .text(let text): return text.text
            case .sticker(let sticker): return sticker.emoji ?? (sticker.assetRef?.kind == .video ? "Video" : "Image")
            case .drawing: return "Drawing"
            case .link(let link): return link.label
            case .interactive(let interactive): return interactive.title
            }
        }
        return nil
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        selectedOverlayID = nil
    }

    func selectOverlay(_ id: UUID?) {
        selectedOverlayID = id
    }

    func split(at timelineSeconds: Double) async {
        guard let match = clipLocation(at: timelineSeconds) else {
            errorMessage = "Move the playhead over a clip to split."
            return
        }
        let localSeconds = max(timelineSeconds - match.start.seconds, 0)
        let clipDuration = match.clip.timelineDuration.seconds
        guard localSeconds > 0.15, localSeconds < clipDuration - 0.15 else {
            errorMessage = "Split point is too close to the clip edge."
            return
        }

        var updated = project
        let leftDuration = localSeconds * max(match.clip.speed, 0.01)
        let rightDuration = max(match.clip.sourceDurationSeconds - leftDuration, 0)
        var left = match.clip.copyWith(sourceStartSeconds: match.clip.sourceStartSeconds, sourceDurationSeconds: leftDuration)
        let right = match.clip.copyWith(sourceStartSeconds: match.clip.sourceStartSeconds + leftDuration, sourceDurationSeconds: rightDuration, newID: UUID())
        left = left.copyWith(newID: UUID())
        updated.tracks.videoClips.remove(at: match.index)
        updated.tracks.videoClips.insert(contentsOf: [left, right], at: match.index)
        await commit(updated, label: "Split")
        selectedClipID = right.id
    }

    func deleteSelectedClip() async {
        guard let index = selectedClipIndex, project.tracks.videoClips.count > 1 else {
            errorMessage = "A story needs at least one clip."
            return
        }
        var updated = project
        updated.tracks.videoClips.remove(at: index)
        let nextIndex = min(index, updated.tracks.videoClips.count - 1)
        await commit(updated, label: "Delete")
        selectedClipID = updated.tracks.videoClips.indices.contains(nextIndex) ? updated.tracks.videoClips[nextIndex].id : nil
    }

    func duplicateSelectedClip() async {
        guard let index = selectedClipIndex else { return }
        let duplicate = project.tracks.videoClips[index].copyWith(newID: UUID())
        var updated = project
        updated.tracks.videoClips.insert(duplicate, at: index + 1)
        guard validateStoryDuration(updated) else {
            errorMessage = "Duplicating this clip would exceed the 60 second story limit."
            return
        }
        await commit(updated, label: "Duplicate")
        selectedClipID = duplicate.id
    }

    func trimSelectedClip(to durationSeconds: Double) async {
        guard let index = selectedClipIndex else { return }
        let original = project.tracks.videoClips[index]
        let maxDuration = original.assetRef.durationSeconds - original.sourceStartSeconds
        let clamped = min(max(durationSeconds * max(original.speed, 0.01), 0.2), max(maxDuration, 0.2))
        var updated = project
        updated.tracks.videoClips[index].sourceDuration = CMTimeValueBox(seconds: clamped)
        guard validateStoryDuration(updated) else {
            errorMessage = "Trim would exceed the 60 second story limit."
            return
        }
        await commit(updated, label: "Trim")
    }

    func moveSelectedClip(by offset: Int) async {
        guard let index = selectedClipIndex else { return }
        let target = index + offset
        guard project.tracks.videoClips.indices.contains(target) else { return }
        var updated = project
        let clip = updated.tracks.videoClips.remove(at: index)
        updated.tracks.videoClips.insert(clip, at: target)
        await commit(updated, label: "Reorder")
        selectedClipID = clip.id
    }

    func addTextOverlay(text: String, style: TextOverlayStyle = .default, at timelineSeconds: Double) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter text before adding an overlay."
            return
        }
        let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
        let duration = min(3, max(project.totalDurationSeconds - start, 0.2))
        let overlay = TextOverlay(
            text: String(trimmed.prefix(80)),
            transform: Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0),
            timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration)),
            style: style
        )
        var updated = project
        updated.tracks.overlays.append(.text(overlay))
        await commit(updated, label: "Add Text")
        selectedOverlayID = overlay.id
    }

    func updateSelectedText(_ text: String, style: TextOverlayStyle? = nil) async {
        guard let id = selectedOverlayID else { return }
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }),
              case .text(var overlay) = updated.tracks.overlays[index] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Text overlay cannot be empty."
            return
        }
        overlay.text = String(trimmed.prefix(80))
        if let style {
            overlay.style = style
        }
        updated.tracks.overlays[index] = .text(overlay)
        await commit(updated, label: "Edit Text")
        selectedOverlayID = id
    }

    func addStickerOverlay(emoji: String, at timelineSeconds: Double) async {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scalar = trimmed.first else {
            errorMessage = "Choose an emoji before adding a sticker."
            return
        }
        let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
        let duration = max(project.totalDurationSeconds - start, 0.2)
        let sticker = StickerOverlay(
            id: UUID(),
            assetRef: nil,
            emoji: String(scalar),
            transform: Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0),
            timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
        )
        var updated = project
        updated.tracks.overlays.append(.sticker(sticker))
        await commit(updated, label: "Add Sticker")
        selectedOverlayID = sticker.id
    }

    func addLinkOverlay(label: String, url: String, at timelineSeconds: Double) async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, Self.isValidStoryURL(trimmedURL) else {
            errorMessage = "Enter a label and a valid HTTPS or app link."
            return
        }
        let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
        let duration = max(project.totalDurationSeconds - start, 0.2)
        let link = LinkOverlay(
            label: String(trimmedLabel.prefix(32)),
            url: trimmedURL,
            transform: Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0),
            timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
        )
        var updated = project
        updated.tracks.overlays.append(.link(link))
        await commit(updated, label: "Add Link")
        selectedOverlayID = link.id
    }

    func updateSelectedLink(label: String, url: String) async {
        guard let id = selectedOverlayID else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, Self.isValidStoryURL(trimmedURL) else {
            errorMessage = "Enter a label and a valid HTTPS or app link."
            return
        }
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }),
              case .link(var link) = updated.tracks.overlays[index] else { return }
        link.label = String(trimmedLabel.prefix(32))
        link.url = trimmedURL
        updated.tracks.overlays[index] = .link(link)
        await commit(updated, label: "Edit Link")
        selectedOverlayID = id
    }

    func addInteractiveOverlay(
        kind: StoryInteractiveStickerKind,
        title: String,
        subtitle: String? = nil,
        options: [String] = [],
        targetDate: Date? = nil,
        at timelineSeconds: Double
    ) async {
        let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
        let duration = max(project.totalDurationSeconds - start, 0.2)
        let overlay = StoryInteractiveOverlay(
            kind: kind,
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            subtitle: subtitle.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) },
            options: options.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36)) }.filter { !$0.isEmpty },
            targetDate: targetDate,
            transform: Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0),
            timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
        )
        var updated = project
        updated.tracks.overlays.append(.interactive(overlay))
        await commit(updated, label: "Add Sticker")
        selectedOverlayID = overlay.id
    }

    func updateSelectedInteractiveOverlay(title: String, subtitle: String?, options: [String], targetDate: Date?) async {
        guard let id = selectedOverlayID else { return }
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }),
              case .interactive(var overlay) = updated.tracks.overlays[index] else { return }
        overlay.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        overlay.subtitle = subtitle.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        overlay.options = options.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36)) }.filter { !$0.isEmpty }
        overlay.targetDate = targetDate
        updated.tracks.overlays[index] = .interactive(overlay)
        await commit(updated, label: "Edit Sticker")
        selectedOverlayID = id
    }

    private static func isValidStoryURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "westreem"
    }

    func addImageOverlay(imageData: Data, width: Int, height: Int, at timelineSeconds: Double) async {
        await addStickerImageOverlay(
            imageData: imageData,
            fileExtension: "jpg",
            width: width,
            height: height,
            label: "Add Image",
            at: timelineSeconds
        )
    }

    func addStickerImageOverlay(
        imageData: Data,
        fileExtension: String,
        width: Int,
        height: Int,
        label: String = "Add Sticker",
        at timelineSeconds: Double
    ) async {
        do {
            let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
            let duration = min(5, max(project.totalDurationSeconds - start, 0.2))
            let store = await ProjectStore.shared.assetStore(for: project.id)
            let relativePath = try store.importData(imageData, extension: fileExtension)
            let assetRef = AssetRef.make(
                kind: .image,
                relativePath: relativePath,
                naturalWidth: width,
                naturalHeight: height,
                nominalFrameRate: 0,
                durationSeconds: duration
            )
            let overlay = StickerOverlay(
                id: UUID(),
                assetRef: assetRef,
                emoji: nil,
                transform: Transform2D(scale: 0.42, rotation: 0, tx: 0, ty: 0),
                timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
            )
            var updated = project
            updated.tracks.overlays.append(.sticker(overlay))
            await commit(updated, label: label)
            selectedOverlayID = overlay.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addVideoOverlay(from url: URL, at timelineSeconds: Double) async {
        do {
            let asset = AVAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                errorMessage = "Could not read the selected video."
                return
            }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = naturalSize.applying(transform)
            let width = abs(transformed.width) > 0 ? abs(transformed.width) : abs(naturalSize.width)
            let height = abs(transformed.height) > 0 ? abs(transformed.height) : abs(naturalSize.height)
            let frameRate = (try? await track.load(.nominalFrameRate)) ?? 0
            let sourceDuration = max((try? await asset.load(.duration).seconds) ?? 0, 0.2)
            let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
            let duration = min(sourceDuration, max(project.totalDurationSeconds - start, 0.2))
            let store = await ProjectStore.shared.assetStore(for: project.id)
            let relativePath = try store.importFile(url, extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            let assetRef = AssetRef.make(
                kind: .video,
                relativePath: relativePath,
                naturalWidth: Int(width),
                naturalHeight: Int(height),
                nominalFrameRate: frameRate,
                durationSeconds: duration,
                preferredTransform: transform
            )
            let overlay = StickerOverlay(
                id: UUID(),
                assetRef: assetRef,
                emoji: nil,
                transform: Transform2D(scale: 0.42, rotation: 0, tx: 0, ty: 0),
                timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
            )
            var updated = project
            updated.tracks.overlays.append(.sticker(overlay))
            await commit(updated, label: "Add Video")
            selectedOverlayID = overlay.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addDrawingOverlay(imageData: Data, width: Int, height: Int, tx: Double = 0, ty: Double = 0, at timelineSeconds: Double) async {
        do {
            let start = min(max(timelineSeconds, 0), max(project.totalDurationSeconds - 0.2, 0))
            let duration = min(3, max(project.totalDurationSeconds - start, 0.2))
            let store = await ProjectStore.shared.assetStore(for: project.id)
            let relativePath = try store.importData(imageData, extension: "png")
            let assetRef = AssetRef.make(
                kind: .image,
                relativePath: relativePath,
                naturalWidth: width,
                naturalHeight: height,
                nominalFrameRate: 0,
                durationSeconds: duration
            )
            let drawing = DrawingOverlay(
                id: UUID(),
                assetRef: assetRef,
                transform: Transform2D(scale: 1, rotation: 0, tx: tx, ty: ty),
                timeRange: TimelineRange(start: CMTimeValueBox(seconds: start), duration: CMTimeValueBox(seconds: duration))
            )
            var updated = project
            updated.tracks.overlays.append(.drawing(drawing))
            await commit(updated, label: "Add Drawing")
            selectedOverlayID = drawing.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedOverlayPosition(tx: Double, ty: Double) async {
        guard let id = selectedOverlayID else { return }
        await setOverlayPosition(id: id, tx: tx, ty: ty)
    }

    func setOverlayPosition(id: UUID, tx: Double, ty: Double) async {
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        switch updated.tracks.overlays[index] {
        case .text(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .text(overlay)
        case .sticker(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .sticker(overlay)
        case .drawing(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .drawing(overlay)
        case .link(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .link(overlay)
        case .interactive(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .interactive(overlay)
        }
        await commit(updated, label: "Move Overlay")
        selectedOverlayID = id
    }

    func setOverlayScale(id: UUID, scale: Double) async {
        updateOverlayScale(id: id, scale: scale)
        await persistInteractiveOverlayEdits()
    }

    func setOverlayPositionLive(id: UUID, tx: Double, ty: Double) {
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        switch updated.tracks.overlays[index] {
        case .text(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .text(overlay)
        case .sticker(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .sticker(overlay)
        case .drawing(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .drawing(overlay)
        case .link(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .link(overlay)
        case .interactive(var overlay):
            overlay.transform.tx = min(max(tx, -420), 420)
            overlay.transform.ty = min(max(ty, -760), 760)
            updated.tracks.overlays[index] = .interactive(overlay)
        }
        project = updated
        selectedOverlayID = id
    }

    func setOverlayScaleLive(id: UUID, scale: Double) {
        updateOverlayScale(id: id, scale: scale)
    }

    func setOverlayTransformLive(id: UUID, transform: Transform2D) {
        let clampedTransform = Transform2D(
            scale: min(max(transform.scale, 0.25), 4),
            rotation: transform.rotation,
            tx: min(max(transform.tx, -420), 420),
            ty: min(max(transform.ty, -760), 760)
        )
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        switch updated.tracks.overlays[index] {
        case .text(var overlay):
            overlay.transform = clampedTransform
            updated.tracks.overlays[index] = .text(overlay)
        case .sticker(var overlay):
            overlay.transform = clampedTransform
            updated.tracks.overlays[index] = .sticker(overlay)
        case .drawing(var overlay):
            overlay.transform = clampedTransform
            updated.tracks.overlays[index] = .drawing(overlay)
        case .link(var overlay):
            overlay.transform = clampedTransform
            updated.tracks.overlays[index] = .link(overlay)
        case .interactive(var overlay):
            overlay.transform = clampedTransform
            updated.tracks.overlays[index] = .interactive(overlay)
        }
        project = updated
        selectedOverlayID = id
    }

    func persistInteractiveOverlayEdits() async {
        var updated = project
        updated.updatedAt = Date()
        project = updated
        await persist()
    }

    private func updateOverlayScale(id: UUID, scale: Double) {
        let clampedScale = min(max(scale, 0.25), 4)
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        switch updated.tracks.overlays[index] {
        case .text(var overlay):
            overlay.transform.scale = clampedScale
            updated.tracks.overlays[index] = .text(overlay)
        case .sticker(var overlay):
            overlay.transform.scale = clampedScale
            updated.tracks.overlays[index] = .sticker(overlay)
        case .drawing(var overlay):
            overlay.transform.scale = clampedScale
            updated.tracks.overlays[index] = .drawing(overlay)
        case .link(var overlay):
            overlay.transform.scale = clampedScale
            updated.tracks.overlays[index] = .link(overlay)
        case .interactive(var overlay):
            overlay.transform.scale = clampedScale
            updated.tracks.overlays[index] = .interactive(overlay)
        }
        project = updated
        selectedOverlayID = id
    }

    func updateSelectedOverlayTime(start: Double, duration: Double) async {
        guard let id = selectedOverlayID else { return }
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        let clampedStart = min(max(start, 0), max(project.totalDurationSeconds - 0.2, 0))
        let maxDuration = max(project.totalDurationSeconds - clampedStart, 0.2)
        let range = TimelineRange(
            start: CMTimeValueBox(seconds: clampedStart),
            duration: CMTimeValueBox(seconds: min(max(duration, 0.2), maxDuration))
        )
        switch updated.tracks.overlays[index] {
        case .text(var overlay):
            overlay.timeRange = range
            updated.tracks.overlays[index] = .text(overlay)
        case .sticker(var overlay):
            overlay.timeRange = range
            updated.tracks.overlays[index] = .sticker(overlay)
        case .drawing(var overlay):
            overlay.timeRange = range
            updated.tracks.overlays[index] = .drawing(overlay)
        case .link(var overlay):
            overlay.timeRange = range
            updated.tracks.overlays[index] = .link(overlay)
        case .interactive(var overlay):
            overlay.timeRange = range
            updated.tracks.overlays[index] = .interactive(overlay)
        }
        await commit(updated, label: "Overlay Timing")
        selectedOverlayID = id
    }

    func applyEffectPreset(_ preset: StoryEffectPreset) async {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].filterId = preset.id
        updated.tracks.videoClips[index].adjustments = preset.adjustments
        await commit(updated, label: "Filter")
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipAdjustments(_ adjustments: ColorAdjust) async {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].adjustments = adjustments
        if updated.tracks.videoClips[index].filterId == nil {
            updated.tracks.videoClips[index].filterId = "custom"
        }
        await commit(updated, label: "Adjust")
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipAudio(volume: Float, muted: Bool) async {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].volume = min(max(volume, 0), 1)
        updated.tracks.videoClips[index].muted = muted
        await commit(updated, label: "Audio")
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipSpeed(_ speed: Double) async {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].speed = min(max(speed, 0.25), 4)
        guard validateStoryDuration(updated) else {
            errorMessage = "This speed would exceed the 60 second story limit."
            return
        }
        await commit(updated, label: "Speed")
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func toggleSelectedClipReverse() async {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].reversed.toggle()
        await commit(updated, label: "Reverse")
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func importMusic(from url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration > 0 else {
                errorMessage = "Could not read the selected audio file."
                return
            }
            let store = await ProjectStore.shared.assetStore(for: project.id)
            let relativePath = try store.importFile(url, extension: "m4a")
            let assetRef = AssetRef.make(
                kind: .audio,
                relativePath: relativePath,
                naturalWidth: 0,
                naturalHeight: 0,
                nominalFrameRate: 0,
                durationSeconds: duration
            )
            let clip = AudioClip(
                id: UUID(),
                assetRef: assetRef,
                startOnTimeline: CMTimeValueBox(seconds: 0),
                sourceStart: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: min(project.totalDurationSeconds, duration)),
                volume: 0.75,
                fadeIn: CMTimeValueBox(seconds: 0.25),
                fadeOut: CMTimeValueBox(seconds: 0.5)
            )
            var updated = project
            updated.tracks.audioClips = [clip]
            await commit(updated, label: "Music")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateMusicVolume(_ volume: Float) async {
        guard !project.tracks.audioClips.isEmpty else { return }
        var updated = project
        updated.tracks.audioClips[0].volume = min(max(volume, 0), 1)
        await commit(updated, label: "Music Volume")
    }

    func removeMusic() async {
        guard !project.tracks.audioClips.isEmpty else { return }
        var updated = project
        updated.tracks.audioClips.removeAll()
        await commit(updated, label: "Remove Music")
    }

    func deleteSelectedOverlay() async {
        guard let id = selectedOverlayID else { return }
        var updated = project
        updated.tracks.overlays.removeAll { $0.id == id }
        await commit(updated, label: "Delete Overlay")
        selectedOverlayID = nil
    }

    func duplicateSelectedOverlay() async {
        guard let id = selectedOverlayID,
              let index = project.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        let duplicate = duplicatedOverlay(from: updated.tracks.overlays[index])
        updated.tracks.overlays.insert(duplicate, at: index + 1)
        await commit(updated, label: "Duplicate Overlay")
        selectedOverlayID = duplicate.id
    }

    func bringSelectedOverlayForward() async {
        guard let id = selectedOverlayID,
              let index = project.tracks.overlays.firstIndex(where: { $0.id == id }),
              index < project.tracks.overlays.count - 1 else { return }
        var updated = project
        updated.tracks.overlays.swapAt(index, index + 1)
        await commit(updated, label: "Bring Overlay Forward")
        selectedOverlayID = id
    }

    func sendSelectedOverlayBackward() async {
        guard let id = selectedOverlayID,
              let index = project.tracks.overlays.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        var updated = project
        updated.tracks.overlays.swapAt(index, index - 1)
        await commit(updated, label: "Send Overlay Backward")
        selectedOverlayID = id
    }

    private func duplicatedOverlay(from overlay: Overlay) -> Overlay {
        switch overlay {
        case .text(let text):
            var transform = text.transform
            transform.tx = min(max(transform.tx + 28, -420), 420)
            transform.ty = min(max(transform.ty - 28, -760), 760)
            return .text(TextOverlay(
                text: text.text,
                transform: transform,
                timeRange: text.timeRange,
                style: text.style
            ))
        case .sticker(let sticker):
            var transform = sticker.transform
            transform.tx = min(max(transform.tx + 28, -420), 420)
            transform.ty = min(max(transform.ty - 28, -760), 760)
            return .sticker(StickerOverlay(
                id: UUID(),
                assetRef: sticker.assetRef,
                emoji: sticker.emoji,
                transform: transform,
                timeRange: sticker.timeRange
            ))
        case .drawing(let drawing):
            var transform = drawing.transform
            transform.tx = min(max(transform.tx + 28, -420), 420)
            transform.ty = min(max(transform.ty - 28, -760), 760)
            return .drawing(DrawingOverlay(
                id: UUID(),
                assetRef: drawing.assetRef,
                transform: transform,
                timeRange: drawing.timeRange
            ))
        case .link(let link):
            var transform = link.transform
            transform.tx = min(max(transform.tx + 28, -420), 420)
            transform.ty = min(max(transform.ty - 28, -760), 760)
            return .link(LinkOverlay(
                label: link.label,
                url: link.url,
                transform: transform,
                timeRange: link.timeRange
            ))
        case .interactive(let interactive):
            var transform = interactive.transform
            transform.tx = min(max(transform.tx + 28, -420), 420)
            transform.ty = min(max(transform.ty - 28, -760), 760)
            return .interactive(StoryInteractiveOverlay(
                kind: interactive.kind,
                title: interactive.title,
                subtitle: interactive.subtitle,
                options: interactive.options,
                targetDate: interactive.targetDate,
                transform: transform,
                timeRange: interactive.timeRange
            ))
        }
    }

    func undo() async {
        guard let command = undoStack.popLast() else { return }
        redoStack.append(command)
        project = command.before
        selectedClipID = project.tracks.videoClips.first?.id
        await persist()
        updateUndoRedoState()
    }

    func redo() async {
        guard let command = redoStack.popLast() else { return }
        undoStack.append(command)
        project = command.after
        selectedClipID = project.tracks.videoClips.first?.id
        await persist()
        updateUndoRedoState()
    }

    private func commit(_ updatedProject: Project, label: String) async {
        var updated = updatedProject
        updated.updatedAt = Date()
        undoStack.append(StoryTimelineCommand(before: project, after: updated, label: label))
        if undoStack.count > maxCommands {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        project = updated
        errorMessage = nil
        await persist()
        updateUndoRedoState()
    }

    private func persist() async {
        do {
            try await ProjectStore.shared.save(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func validateStoryDuration(_ project: Project) -> Bool {
        project.storyDestination == nil || project.totalDurationSeconds <= storyMaxDurationSeconds
    }

    private func clipLocation(at timelineSeconds: Double) -> (clip: VideoClip, index: Int, start: CMTime)? {
        let time = CMTime(seconds: timelineSeconds, preferredTimescale: projectTimeScale)
        var cursor = CMTime.zero
        for (index, clip) in project.tracks.videoClips.enumerated() {
            let end = cursor + clip.timelineDuration
            if time >= cursor && time < end {
                return (clip, index, cursor)
            }
            cursor = end
        }
        return nil
    }
}

extension VideoClip {
    func copyWith(
        sourceStartSeconds: Double? = nil,
        sourceDurationSeconds: Double? = nil,
        newID: UUID? = nil
    ) -> VideoClip {
        VideoClip(
            id: newID ?? id,
            assetRef: assetRef,
            sourceStart: CMTimeValueBox(seconds: sourceStartSeconds ?? self.sourceStartSeconds),
            sourceDuration: CMTimeValueBox(seconds: sourceDurationSeconds ?? self.sourceDurationSeconds),
            speed: speed,
            reversed: reversed,
            volume: volume,
            muted: muted,
            transform: transform,
            cropRect: cropRect,
            filterId: filterId,
            filterIntensity: filterIntensity,
            adjustments: adjustments,
            transitionIn: transitionIn
        )
    }
}
