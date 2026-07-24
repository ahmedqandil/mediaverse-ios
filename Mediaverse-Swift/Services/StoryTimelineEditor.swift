import AVFoundation
import CoreMedia
import Foundation

struct StoryTimelineCommand {
    let before: Project
    let after: Project
    let label: String
    let beforeSelection: StoryTimelineSelection
    let afterSelection: StoryTimelineSelection
}

struct StoryTimelineSelection: Equatable {
    var clipID: UUID?
    var overlayID: UUID?
}

@MainActor
final class StoryTimelineEditor: ObservableObject {
    @Published private(set) var project: Project
    @Published var selectedClipID: UUID?
    @Published var selectedOverlayID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var isSaving = false
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [StoryTimelineCommand] = []
    private var redoStack: [StoryTimelineCommand] = []
    private var pendingOverlayEditBaseline: Project?
    private var saveRevision = 0
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

    private var fullStoryOverlayTimeRange: TimelineRange {
        TimelineRange(
            start: CMTimeValueBox(seconds: 0),
            duration: CMTimeValueBox(seconds: max(project.totalDurationSeconds, 0.2))
        )
    }

    private func defaultOverlayTransform(scale: Double = 1) -> Transform2D {
        let offsets: [(Double, Double)] = [
            (0, 0),
            (42, -42),
            (-42, 42),
            (72, 36),
            (-72, -36),
            (0, 84)
        ]
        let offset = offsets[project.tracks.overlays.count % offsets.count]
        return Transform2D(scale: scale, rotation: 0, tx: offset.0, ty: offset.1)
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

    func previewSelectedClip(_ clip: VideoClip) {
        guard let index = selectedClipIndex else { return }
        project.tracks.videoClips[index] = clip
        selectedClipID = clip.id
        errorMessage = nil
    }

    func commitSelectedClipPreview(baselineClip: VideoClip?, label: String = "Update Clip") async {
        guard let index = selectedClipIndex, let baselineClip else { return }
        var before = project
        before.tracks.videoClips[index] = baselineClip
        await commit(project, label: label, before: before)
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
        await commit(
            updated,
            label: "Split",
            selectionAfter: StoryTimelineSelection(clipID: right.id, overlayID: selectedOverlayID)
        )
    }

    func deleteSelectedClip() async {
        guard let index = selectedClipIndex, project.tracks.videoClips.count > 1 else {
            errorMessage = "A story needs at least one clip."
            return
        }
        var updated = project
        updated.tracks.videoClips.remove(at: index)
        let nextIndex = min(index, updated.tracks.videoClips.count - 1)
        let nextClipID = updated.tracks.videoClips.indices.contains(nextIndex) ? updated.tracks.videoClips[nextIndex].id : nil
        await commit(
            updated,
            label: "Delete",
            selectionAfter: StoryTimelineSelection(clipID: nextClipID, overlayID: selectedOverlayID)
        )
    }

    func duplicateSelectedClip() async {
        guard let index = selectedClipIndex else { return }
        let duplicate = project.tracks.videoClips[index].copyWith(newID: UUID())
        var updated = project
        updated.tracks.videoClips.insert(duplicate, at: index + 1)
        guard validateStoryDuration(updated) else {
            errorMessage = "Duplicating this clip would exceed the 10 second story limit."
            return
        }
        await commit(
            updated,
            label: "Duplicate",
            selectionAfter: StoryTimelineSelection(clipID: duplicate.id, overlayID: selectedOverlayID)
        )
    }

    func previewSelectedClipTrim(to durationSeconds: Double) {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updateClipTrim(in: &updated, at: index, timelineDurationSeconds: durationSeconds)
        guard validateStoryDuration(updated) else {
            errorMessage = "Trim would exceed the 10 second story limit."
            return
        }
        project = updated
        selectedClipID = updated.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitSelectedClipTrim(to durationSeconds: Double, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updateClipTrim(in: &updated, at: index, timelineDurationSeconds: durationSeconds)
        guard validateStoryDuration(updated) else {
            errorMessage = "Trim would exceed the 10 second story limit."
            return
        }
        await commit(updated, label: "Trim", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func trimSelectedClip(to durationSeconds: Double) async {
        await commitSelectedClipTrim(to: durationSeconds, baselineClip: nil)
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
        let overlay = TextOverlay(
            text: String(trimmed.prefix(80)),
            transform: defaultOverlayTransform(),
            timeRange: fullStoryOverlayTimeRange,
            style: style
        )
        var updated = project
        updated.tracks.overlays.append(.text(overlay))
        await commit(
            updated,
            label: "Add Text",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: overlay.id)
        )
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
        let sticker = StickerOverlay(
            id: UUID(),
            assetRef: nil,
            emoji: String(scalar),
            transform: defaultOverlayTransform(),
            timeRange: fullStoryOverlayTimeRange
        )
        var updated = project
        updated.tracks.overlays.append(.sticker(sticker))
        await commit(
            updated,
            label: "Add Sticker",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: sticker.id)
        )
    }

    func addLinkOverlay(label: String, url: String, at timelineSeconds: Double) async {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, Self.isValidStoryURL(trimmedURL) else {
            errorMessage = "Enter a label and a valid HTTPS or app link."
            return
        }
        let link = LinkOverlay(
            label: String(trimmedLabel.prefix(32)),
            url: trimmedURL,
            transform: defaultOverlayTransform(),
            timeRange: fullStoryOverlayTimeRange
        )
        var updated = project
        updated.tracks.overlays.append(.link(link))
        await commit(
            updated,
            label: "Add Link",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: link.id)
        )
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
        let overlay = StoryInteractiveOverlay(
            kind: kind,
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            subtitle: subtitle.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) },
            options: normalizedInteractiveOptions(options),
            targetDate: targetDate,
            transform: defaultOverlayTransform(),
            timeRange: fullStoryOverlayTimeRange
        )
        var updated = project
        updated.tracks.overlays.append(.interactive(overlay))
        await commit(
            updated,
            label: "Add Sticker",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: overlay.id)
        )
    }

    func updateSelectedInteractiveOverlay(title: String, subtitle: String?, options: [String], targetDate: Date?) async {
        guard let id = selectedOverlayID else { return }
        var updated = project
        guard let index = updated.tracks.overlays.firstIndex(where: { $0.id == id }),
              case .interactive(var overlay) = updated.tracks.overlays[index] else { return }
        overlay.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        overlay.subtitle = subtitle.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        overlay.options = normalizedInteractiveOptions(options)
        overlay.targetDate = targetDate
        updated.tracks.overlays[index] = .interactive(overlay)
        await commit(updated, label: "Edit Sticker")
        selectedOverlayID = id
    }

    private func normalizedInteractiveOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(trimmed.contains("=") ? 240 : 36))
        }
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
            let timeRange = fullStoryOverlayTimeRange
            let duration = timeRange.duration.time.seconds
            let store = await ProjectStore.shared.assetStore(for: project.id)
            try Task.checkCancellation()
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
                transform: defaultOverlayTransform(scale: 0.42),
                timeRange: timeRange
            )
            var updated = project
            updated.tracks.overlays.append(.sticker(overlay))
            await commit(
                updated,
                label: label,
                selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: overlay.id)
            )
        } catch {
            guard !Task.isCancelled else { return }
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
            try Task.checkCancellation()
            let timeRange = fullStoryOverlayTimeRange
            let duration = min(sourceDuration, timeRange.duration.time.seconds)
            let store = await ProjectStore.shared.assetStore(for: project.id)
            try Task.checkCancellation()
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
                transform: defaultOverlayTransform(scale: 0.42),
                timeRange: timeRange
            )
            var updated = project
            updated.tracks.overlays.append(.sticker(overlay))
            await commit(
                updated,
                label: "Add Video",
                selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: overlay.id)
            )
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func addDrawingOverlay(imageData: Data, width: Int, height: Int, tx: Double = 0, ty: Double = 0, at timelineSeconds: Double) async {
        do {
            let timeRange = fullStoryOverlayTimeRange
            let duration = timeRange.duration.time.seconds
            let store = await ProjectStore.shared.assetStore(for: project.id)
            try Task.checkCancellation()
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
                timeRange: timeRange
            )
            var updated = project
            updated.tracks.overlays.append(.drawing(drawing))
            await commit(
                updated,
                label: "Add Drawing",
                selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: drawing.id)
            )
        } catch {
            guard !Task.isCancelled else { return }
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
        setOverlayScaleLive(id: id, scale: scale)
        await persistInteractiveOverlayEdits()
    }

    func setOverlayPositionLive(id: UUID, tx: Double, ty: Double) {
        beginOverlayEditIfNeeded()
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
        beginOverlayEditIfNeeded()
        updateOverlayScale(id: id, scale: scale)
    }

    func setOverlayTransformLive(id: UUID, transform: Transform2D) {
        beginOverlayEditIfNeeded()
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
        guard let baseline = pendingOverlayEditBaseline else { return }
        pendingOverlayEditBaseline = nil
        guard baseline != project else { return }
        await commit(project, label: "Transform Overlay", before: baseline)
    }

    private func beginOverlayEditIfNeeded() {
        if pendingOverlayEditBaseline == nil {
            pendingOverlayEditBaseline = project
        }
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

    func previewEffectPreset(_ preset: StoryEffectPreset) {
        guard let index = selectedClipIndex else { return }
        project.tracks.videoClips[index].filterId = preset.id
        project.tracks.videoClips[index].adjustments = preset.adjustments
        selectedClipID = project.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitEffectPreset(_ preset: StoryEffectPreset, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updated.tracks.videoClips[index].filterId = preset.id
        updated.tracks.videoClips[index].adjustments = preset.adjustments
        await commit(updated, label: "Filter", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func applyEffectPreset(_ preset: StoryEffectPreset) async {
        await commitEffectPreset(preset, baselineClip: nil)
    }

    func previewSelectedClipAdjustments(_ adjustments: ColorAdjust) {
        guard let index = selectedClipIndex else { return }
        project.tracks.videoClips[index].adjustments = adjustments
        if project.tracks.videoClips[index].filterId == nil {
            project.tracks.videoClips[index].filterId = "custom"
        }
        selectedClipID = project.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitSelectedClipAdjustments(_ adjustments: ColorAdjust, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updated.tracks.videoClips[index].adjustments = adjustments
        if updated.tracks.videoClips[index].filterId == nil {
            updated.tracks.videoClips[index].filterId = "custom"
        }
        await commit(updated, label: "Adjust", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipAdjustments(_ adjustments: ColorAdjust) async {
        await commitSelectedClipAdjustments(adjustments, baselineClip: nil)
    }

    func previewSelectedClipAudio(volume: Float, muted: Bool) {
        guard let index = selectedClipIndex else { return }
        project.tracks.videoClips[index].volume = min(max(volume, 0), 1)
        project.tracks.videoClips[index].muted = muted
        selectedClipID = project.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitSelectedClipAudio(volume: Float, muted: Bool, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updated.tracks.videoClips[index].volume = min(max(volume, 0), 1)
        updated.tracks.videoClips[index].muted = muted
        await commit(updated, label: "Audio", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipAudio(volume: Float, muted: Bool) async {
        await commitSelectedClipAudio(volume: volume, muted: muted, baselineClip: nil)
    }

    func previewSelectedClipSpeed(_ speed: Double) {
        guard let index = selectedClipIndex else { return }
        var updated = project
        updated.tracks.videoClips[index].speed = min(max(speed, 0.25), 4)
        guard validateStoryDuration(updated) else {
            errorMessage = "This speed would exceed the 10 second story limit."
            return
        }
        project = updated
        selectedClipID = updated.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitSelectedClipSpeed(_ speed: Double, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updated.tracks.videoClips[index].speed = min(max(speed, 0.25), 4)
        guard validateStoryDuration(updated) else {
            errorMessage = "This speed would exceed the 10 second story limit."
            return
        }
        await commit(updated, label: "Speed", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func updateSelectedClipSpeed(_ speed: Double) async {
        await commitSelectedClipSpeed(speed, baselineClip: nil)
    }

    func previewSelectedClipReverse(_ reversed: Bool) {
        guard let index = selectedClipIndex else { return }
        project.tracks.videoClips[index].reversed = reversed
        selectedClipID = project.tracks.videoClips[index].id
        errorMessage = nil
    }

    func commitSelectedClipReverse(_ reversed: Bool, baselineClip: VideoClip?) async {
        guard let index = selectedClipIndex else { return }
        var before = project
        if let baselineClip {
            before.tracks.videoClips[index] = baselineClip
        }
        var updated = project
        updated.tracks.videoClips[index].reversed = reversed
        await commit(updated, label: "Reverse", before: before)
        selectedClipID = updated.tracks.videoClips[index].id
    }

    func toggleSelectedClipReverse() async {
        guard let index = selectedClipIndex else { return }
        await commitSelectedClipReverse(!project.tracks.videoClips[index].reversed, baselineClip: nil)
    }

    func importMusic(from url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard duration > 0 else {
                errorMessage = "Could not read the selected audio file."
                return
            }
            let store = await ProjectStore.shared.assetStore(for: project.id)
            try Task.checkCancellation()
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
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func previewMusicVolume(_ volume: Float) {
        guard !project.tracks.audioClips.isEmpty else { return }
        project.tracks.audioClips[0].volume = min(max(volume, 0), 1)
        errorMessage = nil
    }

    func commitMusicVolume(_ volume: Float, baselineClip: AudioClip?) async {
        guard !project.tracks.audioClips.isEmpty else { return }
        let clampedVolume = min(max(volume, 0), 1)
        if let baselineClip, baselineClip.volume == clampedVolume {
            project.tracks.audioClips[0] = baselineClip
            return
        }
        var before = project
        if let baselineClip {
            before.tracks.audioClips[0] = baselineClip
        }
        var updated = project
        updated.tracks.audioClips[0].volume = clampedVolume
        await commit(updated, label: "Music Volume", before: before)
    }

    func updateMusicVolume(_ volume: Float) async {
        await commitMusicVolume(volume, baselineClip: nil)
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
        await commit(
            updated,
            label: "Delete Overlay",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: nil)
        )
    }

    func duplicateSelectedOverlay() async {
        guard let id = selectedOverlayID,
              let index = project.tracks.overlays.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        let duplicate = duplicatedOverlay(from: updated.tracks.overlays[index])
        updated.tracks.overlays.insert(duplicate, at: index + 1)
        await commit(
            updated,
            label: "Duplicate Overlay",
            selectionAfter: StoryTimelineSelection(clipID: selectedClipID, overlayID: duplicate.id)
        )
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
        selectedClipID = command.beforeSelection.clipID
        selectedOverlayID = command.beforeSelection.overlayID
        reconcileSelection()
        await persist()
        updateUndoRedoState()
    }

    func redo() async {
        guard let command = redoStack.popLast() else { return }
        undoStack.append(command)
        project = command.after
        selectedClipID = command.afterSelection.clipID
        selectedOverlayID = command.afterSelection.overlayID
        reconcileSelection()
        await persist()
        updateUndoRedoState()
    }

    private func reconcileSelection() {
        if let selectedClipID,
           !project.tracks.videoClips.contains(where: { $0.id == selectedClipID }) {
            self.selectedClipID = project.tracks.videoClips.first?.id
        }
        if let selectedOverlayID,
           !project.tracks.overlays.contains(where: { $0.id == selectedOverlayID }) {
            self.selectedOverlayID = nil
        }
    }

    private func commit(
        _ updatedProject: Project,
        label: String,
        before beforeProject: Project? = nil,
        selectionAfter: StoryTimelineSelection? = nil
    ) async {
        var before = beforeProject ?? project
        before.updatedAt = project.updatedAt
        var comparableUpdated = updatedProject
        comparableUpdated.updatedAt = before.updatedAt
        guard comparableUpdated != before else {
            project = before
            errorMessage = nil
            return
        }
        var updated = updatedProject
        updated.updatedAt = Date()
        let beforeSelection = StoryTimelineSelection(clipID: selectedClipID, overlayID: selectedOverlayID)
        let afterSelection = selectionAfter ?? beforeSelection
        undoStack.append(
            StoryTimelineCommand(
                before: before,
                after: updated,
                label: label,
                beforeSelection: beforeSelection,
                afterSelection: afterSelection
            )
        )
        if undoStack.count > maxCommands {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        project = updated
        selectedClipID = afterSelection.clipID
        selectedOverlayID = afterSelection.overlayID
        reconcileSelection()
        errorMessage = nil
        await persist()
        updateUndoRedoState()
    }

    private func persist() async {
        saveRevision += 1
        let revision = saveRevision
        isSaving = true
        do {
            try await ProjectStore.shared.save(project)
            if revision == saveRevision {
                persistenceErrorMessage = nil
                isSaving = false
            }
        } catch {
            if revision == saveRevision {
                persistenceErrorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func validateStoryDuration(_ project: Project) -> Bool {
        project.totalDurationSeconds <= storyMaxDurationSeconds + 0.05
    }

    private func updateClipTrim(in project: inout Project, at index: Int, timelineDurationSeconds: Double) {
        let original = project.tracks.videoClips[index]
        let maxDuration = original.assetRef.durationSeconds - original.sourceStartSeconds
        let clamped = min(max(timelineDurationSeconds * max(original.speed, 0.01), 0.2), max(maxDuration, 0.2))
        project.tracks.videoClips[index].sourceDuration = CMTimeValueBox(seconds: clamped)
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
