import XCTest
import CoreImage
import CoreMedia
@testable import Mediaverse

final class StoryTimedMediaOverlayTests: XCTestCase {
    func testOverlayMediaLoopsAgainstItsOwnDuration() {
        XCTAssertEqual(storyLoopedMediaTime(elapsed: 0.5, duration: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(storyLoopedMediaTime(elapsed: 2.5, duration: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(storyLoopedMediaTime(elapsed: 6, duration: 2), 0, accuracy: 0.0001)
    }

    func testInvalidOrNegativeTimesResolveSafely() {
        XCTAssertEqual(storyLoopedMediaTime(elapsed: -1, duration: 2), 0)
        XCTAssertEqual(storyLoopedMediaTime(elapsed: 1, duration: 0), 0)
        XCTAssertEqual(storyLoopedMediaTime(elapsed: .infinity, duration: 2), 0)
    }

    func testAnimatedOverlaysForceVideoExportForPhotoStories() {
        XCTAssertFalse(storyProjectRequiresAnimatedExport(projectWithOverlay(kind: .image, path: "media/sticker.png")))
        XCTAssertTrue(storyProjectRequiresAnimatedExport(projectWithOverlay(kind: .image, path: "media/sticker.gif")))
        XCTAssertTrue(storyProjectRequiresAnimatedExport(projectWithOverlay(kind: .image, path: "media/sticker.webp")))
        XCTAssertTrue(storyProjectRequiresAnimatedExport(projectWithOverlay(kind: .video, path: "media/overlay.mov")))
    }

    func testPhotoStoryWithStickerExtendsToTenSeconds() {
        var project = projectWithOverlay(kind: .image, path: "media/sticker.gif")

        extendPhotoStoryToMaxDuration(&project)

        XCTAssertEqual(project.totalDurationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(project.tracks.overlays.first?.timeRange.duration.time.seconds ?? -1, 10, accuracy: 0.001)
    }

    func testPlainPhotoStoryAlsoExtendsToTenSeconds() {
        var project = projectWithOverlay(kind: .image, path: "media/sticker.png")
        project.tracks.overlays.removeAll()

        extendPhotoStoryToMaxDuration(&project)

        XCTAssertEqual(project.totalDurationSeconds, 10, accuracy: 0.001)
        XCTAssertTrue(project.tracks.overlays.isEmpty)
    }

    func testCustomStickerTimingIsNotExpanded() {
        var project = projectWithOverlay(kind: .image, path: "media/sticker.gif")
        project.tracks.overlays[0].timeRange = TimelineRange(
            start: CMTimeValueBox(seconds: 1),
            duration: CMTimeValueBox(seconds: 2)
        )

        extendPhotoStoryToMaxDuration(&project)

        XCTAssertEqual(project.totalDurationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(project.tracks.overlays[0].timeRange.start.time.seconds, 1, accuracy: 0.001)
        XCTAssertEqual(project.tracks.overlays[0].timeRange.duration.time.seconds, 2, accuracy: 0.001)
    }

    private func projectWithOverlay(kind: AssetKind, path: String) -> Project {
        var project = Project.storyDraft(title: "Animated export", destination: nil)
        let background = AssetRef.make(
            kind: .image,
            relativePath: "media/background.jpg",
            naturalWidth: 1080,
            naturalHeight: 1920,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        try! project.addStoryClip(.storyClip(assetRef: background, durationSeconds: 5))
        let overlayAsset = AssetRef.make(
            kind: kind,
            relativePath: path,
            naturalWidth: 320,
            naturalHeight: 320,
            nominalFrameRate: kind == .video ? 30 : 0,
            durationSeconds: 2
        )
        project.tracks.overlays = [
            .sticker(StickerOverlay(
                id: UUID(),
                assetRef: overlayAsset,
                emoji: nil,
                transform: .identity,
                timeRange: TimelineRange(
                    start: CMTimeValueBox(seconds: 0),
                    duration: CMTimeValueBox(seconds: 5)
                )
            ))
        ]
        return project
    }
}

final class StoryMediaQualityTests: XCTestCase {
    func testNativeVideoUsesSameAspectFillGeometryAsStoryRenderer() {
        XCTAssertEqual(
            storyAspectFillScale(
                source: CGSize(width: 1920, height: 1080),
                canvas: CGSize(width: 1080, height: 1920)
            ),
            1920.0 / 1080.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            storyAspectFillScale(
                source: CGSize(width: 1080, height: 1920),
                canvas: CGSize(width: 1080, height: 1920)
            ),
            1,
            accuracy: 0.0001
        )
    }
}

@MainActor
final class StoryClipRangeEditingTests: XCTestCase {
    func testClipRangeUpdatesBothInAndOutPoints() {
        let editor = StoryTimelineEditor(project: projectWithClip(duration: 8))

        editor.previewSelectedClipRange(startSeconds: 2, endSeconds: 6.5)

        XCTAssertEqual(editor.selectedClip?.sourceStartSeconds ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(editor.selectedClip?.sourceDurationSeconds ?? -1, 4.5, accuracy: 0.001)
        XCTAssertFalse(editor.canUndo)
    }

    func testClipRangeClampsToAssetAndMinimumDuration() {
        let editor = StoryTimelineEditor(project: projectWithClip(duration: 8))

        editor.previewSelectedClipRange(startSeconds: 20, endSeconds: 20)

        XCTAssertEqual(editor.selectedClip?.sourceStartSeconds ?? -1, 7.8, accuracy: 0.001)
        XCTAssertEqual(editor.selectedClip?.sourceDurationSeconds ?? -1, 0.2, accuracy: 0.001)
    }

    func testCommittedClipRangeIsUndoable() async {
        let editor = StoryTimelineEditor(project: projectWithClip(duration: 8))
        let baseline = try! XCTUnwrap(editor.selectedClip)

        await editor.commitSelectedClipRange(startSeconds: 1, endSeconds: 5, baselineClip: baseline)
        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.selectedClip?.sourceStartSeconds ?? -1, 1, accuracy: 0.001)

        await editor.undo()
        XCTAssertEqual(editor.selectedClip, baseline)
    }

    private func projectWithClip(duration: Double) -> Project {
        var project = Project.storyDraft(title: "Trim test", destination: nil)
        let asset = AssetRef.make(
            kind: .video,
            relativePath: "media/source.mov",
            naturalWidth: 1080,
            naturalHeight: 1920,
            nominalFrameRate: 30,
            durationSeconds: duration
        )
        try! project.addStoryClip(.storyClip(assetRef: asset, durationSeconds: duration))
        return project
    }
}

@MainActor
final class StoryTimelineMusicEditingTests: XCTestCase {
    func testMusicVolumePreviewClampsWithoutCreatingUndoCommand() {
        let editor = StoryTimelineEditor(project: projectWithMusic(volume: 0.5))

        editor.previewMusicVolume(2)

        XCTAssertEqual(editor.project.tracks.audioClips.first?.volume, 1)
        XCTAssertFalse(editor.canUndo)
    }

    func testUnchangedMusicVolumeDoesNotCreateUndoCommand() async {
        let project = projectWithMusic(volume: 0.5)
        let editor = StoryTimelineEditor(project: project)

        editor.previewMusicVolume(0.5)
        await editor.commitMusicVolume(0.5, baselineClip: project.tracks.audioClips[0])

        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.project.tracks.audioClips.first?.volume, 0.5)
    }

    private func projectWithMusic(volume: Float) -> Project {
        var project = Project.storyDraft(title: "Music test", destination: nil)
        let asset = AssetRef.make(
            kind: .audio,
            relativePath: "media/music.m4a",
            naturalWidth: 0,
            naturalHeight: 0,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        project.tracks.audioClips = [
            AudioClip(
                id: UUID(),
                assetRef: asset,
                startOnTimeline: CMTimeValueBox(seconds: 0),
                sourceStart: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5),
                volume: volume,
                fadeIn: CMTimeValueBox(seconds: 0),
                fadeOut: CMTimeValueBox(seconds: 0)
            )
        ]
        return project
    }
}

@MainActor
final class StoryTimelineOverlayEditingTests: XCTestCase {
    func testLiveOverlayTransformCommitsAsSingleUndoableEdit() async {
        var project = Project.storyDraft(title: "Overlay test", destination: nil)
        let overlay = TextOverlay(
            text: "Hello",
            transform: .identity,
            timeRange: TimelineRange(
                start: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5)
            )
        )
        project.tracks.overlays = [.text(overlay)]
        let editor = StoryTimelineEditor(project: project)

        editor.setOverlayTransformLive(
            id: overlay.id,
            transform: Transform2D(scale: 1.5, rotation: 0.2, tx: 120, ty: -80)
        )
        editor.setOverlayTransformLive(
            id: overlay.id,
            transform: Transform2D(scale: 1.75, rotation: 0.3, tx: 160, ty: -100)
        )
        await editor.persistInteractiveOverlayEdits()

        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.selectedTextOverlay?.transform.tx, 160)

        await editor.undo()

        guard case .text(let restored) = editor.project.tracks.overlays.first else {
            return XCTFail("Expected restored text overlay")
        }
        XCTAssertEqual(restored.transform, .identity)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
    }

    func testUnchangedOverlayGestureDoesNotCreateUndoCommand() async {
        var project = Project.storyDraft(title: "Overlay test", destination: nil)
        let overlay = TextOverlay(
            text: "Hello",
            transform: .identity,
            timeRange: TimelineRange(
                start: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5)
            )
        )
        project.tracks.overlays = [.text(overlay)]
        let editor = StoryTimelineEditor(project: project)

        editor.setOverlayTransformLive(id: overlay.id, transform: .identity)
        await editor.persistInteractiveOverlayEdits()

        XCTAssertFalse(editor.canUndo)
    }

    func testUndoClearsSelectionWhenAddedOverlayNoLongerExists() async {
        let editor = StoryTimelineEditor(
            project: Project.storyDraft(title: "Overlay test", destination: nil)
        )

        await editor.addTextOverlay(text: "Temporary", at: 0)
        XCTAssertNotNil(editor.selectedOverlayID)

        await editor.undo()

        XCTAssertTrue(editor.project.tracks.overlays.isEmpty)
        XCTAssertNil(editor.selectedOverlayID)

        await editor.redo()

        XCTAssertEqual(editor.project.tracks.overlays.count, 1)
        XCTAssertEqual(editor.selectedOverlayID, editor.project.tracks.overlays.first?.id)
    }

    func testApplyingUnchangedTextDoesNotCreateUndoCommand() async {
        var project = Project.storyDraft(title: "Overlay test", destination: nil)
        let overlay = TextOverlay(
            text: "Unchanged",
            transform: .identity,
            timeRange: TimelineRange(
                start: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5)
            )
        )
        project.tracks.overlays = [.text(overlay)]
        let editor = StoryTimelineEditor(project: project)
        editor.selectOverlay(overlay.id)

        await editor.updateSelectedText("Unchanged")

        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.project, project)
    }

    func testOverlayTimingClampsToStoryAndIsUndoable() async {
        var project = Project.storyDraft(title: "Overlay timing", destination: nil)
        let asset = AssetRef.make(
            kind: .image,
            relativePath: "media/story.jpg",
            naturalWidth: 1080,
            naturalHeight: 1920,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        try! project.addStoryClip(.storyClip(assetRef: asset, durationSeconds: 5))
        let overlay = TextOverlay(
            text: "Timed",
            transform: .identity,
            timeRange: TimelineRange(
                start: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5)
            )
        )
        project.tracks.overlays = [.text(overlay)]
        let editor = StoryTimelineEditor(project: project)
        editor.selectOverlay(overlay.id)

        await editor.updateSelectedOverlayTime(start: 4.8, duration: 4)

        let updated = try! XCTUnwrap(editor.selectedOverlay)
        XCTAssertEqual(updated.timeRange.start.time.seconds, 4.8, accuracy: 0.001)
        XCTAssertEqual(updated.timeRange.duration.time.seconds, 0.2, accuracy: 0.001)
        XCTAssertTrue(editor.canUndo)

        await editor.undo()

        XCTAssertEqual(editor.selectedOverlay?.timeRange, overlay.timeRange)
    }
}

final class StoryProjectAssetCleanupTests: XCTestCase {
    func testPruneRemovesOnlyUnreferencedMediaFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        var project = Project.storyDraft(title: "Cleanup test", destination: nil)
        let assetStore = await store.assetStore(for: project.id)
        try assetStore.ensureDirectories()
        let keptPath = try assetStore.importData(Data("kept".utf8), extension: "jpg")
        let removedPath = try assetStore.importData(Data("unused".utf8), extension: "png")
        let keptAsset = AssetRef.make(
            kind: .image,
            relativePath: keptPath,
            naturalWidth: 100,
            naturalHeight: 100,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        project.tracks.videoClips = [.storyClip(assetRef: keptAsset, durationSeconds: 5)]

        try await store.pruneUnreferencedAssets(in: project)

        XCTAssertTrue(FileManager.default.fileExists(atPath: assetStore.absoluteURL(for: keptPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetStore.absoluteURL(for: removedPath).path))
    }
}

final class AdBreakSchedulerTests: XCTestCase {
    func testFindsBreakCrossedByLargePlaybackJump() {
        let breaks = [
            AdBreak(id: "first", breakId: "first", timeOffsetSec: 30, placement: "midroll"),
            AdBreak(id: "second", breakId: "second", timeOffsetSec: 60, placement: "midroll")
        ]

        let due = AdBreakScheduler.nextDue(
            in: breaks,
            watchedIds: [],
            pendingIds: [],
            from: 10,
            to: 65
        )

        XCTAssertEqual(due?.id, "first")
    }

    func testIgnoresWatchedAndPendingBreaks() {
        let breaks = [
            AdBreak(id: "watched", breakId: "watched", timeOffsetSec: 20, placement: "midroll"),
            AdBreak(id: "pending", breakId: "pending", timeOffsetSec: 30, placement: "midroll"),
            AdBreak(id: "eligible", breakId: "eligible", timeOffsetSec: 40, placement: "midroll")
        ]

        let due = AdBreakScheduler.nextDue(
            in: breaks,
            watchedIds: ["watched"],
            pendingIds: ["pending"],
            from: 10,
            to: 45
        )

        XCTAssertEqual(due?.id, "eligible")
    }

    func testDoesNotScheduleWhileSeekingBackward() {
        let breaks = [
            AdBreak(id: "break", breakId: "break", timeOffsetSec: 30, placement: "midroll")
        ]

        XCTAssertNil(
            AdBreakScheduler.nextDue(
                in: breaks,
                watchedIds: [],
                pendingIds: [],
                from: 50,
                to: 20
            )
        )
    }
}

final class VMAPBreakParserTests: XCTestCase {
    func testParsesAbsolutePercentageAndEndOffsets() throws {
        let xml = """
        <vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap">
          <vmap:AdBreak breakId="midroll-absolute" timeOffset="00:00:30"/>
          <vmap:AdBreak breakId="midroll-percent" timeOffset="50%"/>
          <vmap:AdBreak breakId="postroll" timeOffset="end"/>
        </vmap:VMAP>
        """

        let breaks = try VMAPBreakParser.parse(Data(xml.utf8), durationSec: 120)

        XCTAssertEqual(breaks.map(\.timeOffsetSec), [30, 60, 120])
        XCTAssertEqual(breaks.map(\.placement), ["midroll", "midroll", "postroll"])
    }

    func testExcludesStartBecausePrerollUsesExplicitDecisionRequest() throws {
        let xml = """
        <VMAP>
          <AdBreak breakId="preroll" timeOffset="start"/>
          <AdBreak breakId="midroll" timeOffset="00:01:00"/>
        </VMAP>
        """

        let breaks = try VMAPBreakParser.parse(Data(xml.utf8), durationSec: 120)

        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks.first?.placement, "midroll")
    }

    func testRejectsMalformedXML() {
        XCTAssertThrowsError(
            try VMAPBreakParser.parse(Data("<VMAP><AdBreak".utf8), durationSec: 120)
        )
    }
}

final class SGAIPlaybackTests: XCTestCase {
    func testAdsDisabledAlwaysReturnsNone() {
        let policy = EffectiveAdPolicy.disabled(reason: "subscriber")
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .none)
    }

    func testNativeAppOverrideSelectsCSAI() throws {
        let data = Data(#"{"adsEnabled":true,"deliveryMode":"server","deliveryByDevice":{"nativeApp":"csai"}}"#.utf8)
        let policy = try JSONDecoder().decode(EffectiveAdPolicy.self, from: data)
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .csai)
    }

    func testAutoDefaultsToSGAIAndUnsupportedFallsBackToCSAI() throws {
        let policy = try JSONDecoder().decode(
            EffectiveAdPolicy.self,
            from: Data(#"{"adsEnabled":true,"deliveryByDevice":{"nativeApp":"auto"}}"#.utf8)
        )
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy), .sgai)
        XCTAssertEqual(AdDeliveryResolver.resolve(policy: policy, supportsHLSInterstitials: false), .csai)
    }

    func testWrappedURLCarriesStablePlaybackAndContinuationContext() throws {
        let stream = try XCTUnwrap(URL(string: "https://example.com/manifest/video.m3u8?token=a+b"))
        let context = SGAIPlaybackContext(
            contentId: "video-1",
            contentType: "video",
            sessionId: "playback-uuid",
            userId: "user-1",
            deviceId: "device-1",
            country: "JO",
            orientation: "HORIZONTAL",
            entry: PlaybackEntryContext(
                surface: .homeFeed,
                mode: .autoplayPreview,
                contentStartSec: 12.5,
                previewSessionId: "preview-uuid"
            )
        )

        let wrapped = SGAIPlaybackURLBuilder.makeURL(streamMaster: stream, mode: .sgai, context: context)
        let components = try XCTUnwrap(URLComponents(url: wrapped, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(query["u"], stream.absoluteString)
        XCTAssertEqual(query["sessionId"], "playback-uuid")
        XCTAssertEqual(query["entrySurface"], "home_feed")
        XCTAssertEqual(query["entryMode"], "autoplay_preview")
        XCTAssertEqual(query["contentStartSec"], "12.5")
        XCTAssertEqual(query["previewSessionId"], "preview-uuid")
        XCTAssertNil(query["breaks"], "Break cadence must remain server-owned")
    }

    func testCSAILeavesContentURLUnchanged() throws {
        let stream = try XCTUnwrap(URL(string: "https://example.com/video.m3u8"))
        let context = SGAIPlaybackContext(
            contentId: "v",
            contentType: "video",
            sessionId: "s",
            userId: nil,
            deviceId: nil,
            country: nil,
            orientation: "HORIZONTAL",
            entry: .direct
        )
        XCTAssertEqual(
            SGAIPlaybackURLBuilder.makeURL(streamMaster: stream, mode: .csai, context: context),
            stream
        )
    }

    func testAssetListDecodingAndBreakIdentifier() throws {
        let data = Data("""
        {"ASSETS":[{
          "URI":"https://example.com/ad.m3u8",
          "DURATION":15,
          "X-WESTREEM-IID":"iid",
          "X-WESTREEM-DID":"did",
          "X-WESTREEM-SKIPPABLE":1,
          "X-WESTREEM-SKIP-OFFSET":5
        }]}
        """.utf8)

        let list = try JSONDecoder().decode(SGAIAssetList.self, from: data)
        XCTAssertEqual(list.assets.first?.impressionId, "iid")
        XCTAssertEqual(list.assets.first?.skipOffsetSec, 5)
        XCTAssertEqual(SGAIBreakIdentifier.breakId(from: "ad-midroll-2-0"), "midroll-2")
    }

    func testTrackingNeverFiresImpressionAndDeduplicatesEvents() {
        var state = SGAITrackingState()
        XCTAssertFalse(state.shouldFire(event: "impression", impressionId: "iid"))
        XCTAssertTrue(state.shouldFire(event: "start", impressionId: "iid"))
        XCTAssertFalse(state.shouldFire(event: "start", impressionId: "iid"))
        XCTAssertTrue(state.shouldFire(event: "complete", impressionId: "iid"))
        XCTAssertFalse(state.shouldFire(event: "start", impressionId: nil))
    }
}

final class StoryOverlayLayoutTests: XCTestCase {
    private let canvas = CanvasSpec.storyDefault

    func testTransformAndNormalizedBaseRoundTrip() {
        let original = Transform2D(scale: 1.4, rotation: .pi / 3, tx: 260, ty: -410)

        let base = StoryOverlayLayout.normalizedBase(from: original, canvas: canvas)
        let restored = StoryOverlayLayout.transform(from: base, canvas: canvas)

        XCTAssertEqual(restored.tx, original.tx, accuracy: 0.0001)
        XCTAssertEqual(restored.ty, original.ty, accuracy: 0.0001)
        XCTAssertEqual(restored.scale, original.scale, accuracy: 0.0001)
        XCTAssertEqual(restored.rotation, original.rotation, accuracy: 0.0001)
    }

    func testCoordinatesUseFittedStoryFrame() {
        let viewport = CGSize(width: 844, height: 390)
        let frame = StoryOverlayLayout.storyFrame(for: canvas, in: viewport)
        let center = StoryOverlayLayout.position(
            for: StoryOverlayBase(x: 0.5, y: 0.5, scale: 1, rotation: 0),
            canvas: canvas,
            in: viewport
        )

        XCTAssertEqual(center.x, frame.midX, accuracy: 0.0001)
        XCTAssertEqual(center.y, frame.midY, accuracy: 0.0001)
        XCTAssertLessThan(frame.width, viewport.width)
        XCTAssertEqual(frame.height, viewport.height, accuracy: 0.0001)
    }

    func testFullRotatedStickerBoundsStayInsideSafeFrame() {
        let viewports = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932)
        ]
        let rotations = [0.0, Double.pi / 4, Double.pi / 2, Double.pi]

        for viewport in viewports {
            for rotation in rotations {
                let stickerSize = CGSize(width: 260, height: 240)
                let clamped = StoryOverlayLayout.clampedInteractiveTransform(
                    Transform2D(scale: 4, rotation: rotation, tx: 10_000, ty: 10_000),
                    stickerSize: stickerSize,
                    canvas: canvas,
                    viewportSize: viewport
                )
                let center = StoryOverlayLayout.position(for: clamped, canvas: canvas, in: viewport)
                let safeFrame = StoryOverlayLayout.safeFrame(for: canvas, in: viewport)
                let presentationScale = StoryOverlayLayout.stickerPresentationScale(for: canvas, in: viewport)
                let width = stickerSize.width * presentationScale
                let height = stickerSize.height * presentationScale
                let cosine = abs(cos(CGFloat(clamped.rotation)))
                let sine = abs(sin(CGFloat(clamped.rotation)))
                let halfWidth = (width * cosine + height * sine) * CGFloat(clamped.scale) / 2
                let halfHeight = (width * sine + height * cosine) * CGFloat(clamped.scale) / 2

                XCTAssertGreaterThanOrEqual(center.x - halfWidth, safeFrame.minX - 0.001)
                XCTAssertLessThanOrEqual(center.x + halfWidth, safeFrame.maxX + 0.001)
                XCTAssertGreaterThanOrEqual(center.y - halfHeight, safeFrame.minY - 0.001)
                XCTAssertLessThanOrEqual(center.y + halfHeight, safeFrame.maxY + 0.001)
                XCTAssertGreaterThanOrEqual(clamped.scale, StoryOverlayLayout.minimumScale)
                XCTAssertLessThanOrEqual(clamped.scale, StoryOverlayLayout.maximumScale)
            }
        }
    }

    func testMalformedServerCoordinatesAreSanitized() {
        let sanitized = StoryOverlayLayout.sanitizedBase(
            StoryOverlayBase(x: .infinity, y: -.infinity, scale: .nan, rotation: .infinity)
        )

        XCTAssertEqual(sanitized.x, 0.5)
        XCTAssertEqual(sanitized.y, 0.5)
        XCTAssertEqual(sanitized.scale, 1)
        XCTAssertEqual(sanitized.rotation, 0)
    }

    func testPublishMappingUsesSafeBounds() {
        let overlay = StoryInteractiveOverlay(
            kind: .poll,
            title: "A long poll question",
            subtitle: nil,
            options: ["One", "Two", "Three", "Four"],
            targetDate: nil,
            transform: Transform2D(scale: 4, rotation: .pi / 4, tx: 5_000, ty: -5_000),
            timeRange: TimelineRange(
                start: CMTimeValueBox(seconds: 0),
                duration: CMTimeValueBox(seconds: 5)
            )
        )

        let base = StoryOverlayLayout.safeNormalizedBase(for: overlay, canvas: canvas)

        XCTAssertGreaterThanOrEqual(base.x, StoryOverlayLayout.safeBounds.minX)
        XCTAssertLessThanOrEqual(base.x, StoryOverlayLayout.safeBounds.maxX)
        XCTAssertGreaterThanOrEqual(base.y, StoryOverlayLayout.safeBounds.minY)
        XCTAssertLessThanOrEqual(base.y, StoryOverlayLayout.safeBounds.maxY)
        XCTAssertGreaterThanOrEqual(base.scale ?? 0, StoryOverlayLayout.minimumScale)
        XCTAssertLessThanOrEqual(base.scale ?? 10, StoryOverlayLayout.maximumScale)
    }

    func testRotationAndScaleAreNormalizedForPayload() {
        let base = StoryOverlayLayout.normalizedBase(
            from: Transform2D(scale: 99, rotation: .pi * 7, tx: 0, ty: 0),
            canvas: canvas
        )

        XCTAssertEqual(base.scale ?? 0, StoryOverlayLayout.maximumScale, accuracy: 0.0001)
        XCTAssertEqual(base.rotation ?? 0, 180, accuracy: 0.0001)
    }

    func testPresentationScaleDependsOnStoryViewport() {
        let compact = StoryOverlayLayout.stickerPresentationScale(
            for: canvas,
            in: CGSize(width: 320, height: 568)
        )
        let regular = StoryOverlayLayout.stickerPresentationScale(
            for: canvas,
            in: CGSize(width: 390, height: 844)
        )

        XCTAssertEqual(compact, 320.0 / 390.0, accuracy: 0.0001)
        XCTAssertEqual(regular, 1, accuracy: 0.0001)
    }

    func testEveryInteractiveStickerHasUsableGeometry() {
        let kinds: [StoryInteractiveStickerKind] = [
            .link, .location, .mention, .addYours, .poll, .quiz, .question, .countdown, .avatar
        ]

        for kind in kinds {
            let overlay = StoryInteractiveOverlay(
                kind: kind,
                title: "Sticker",
                options: kind == .poll || kind == .quiz ? ["One", "Two"] : [],
                transform: Transform2D(scale: 1, rotation: 0, tx: 0, ty: 0),
                timeRange: TimelineRange(
                    start: CMTimeValueBox(seconds: 0),
                    duration: CMTimeValueBox(seconds: 5)
                )
            )
            let size = StoryOverlayLayout.estimatedStickerSize(for: overlay)
            let base = StoryOverlayLayout.safeNormalizedBase(for: overlay, canvas: canvas)

            XCTAssertGreaterThanOrEqual(size.width, 44, "\(kind) width")
            XCTAssertGreaterThanOrEqual(size.height, 34, "\(kind) height")
            XCTAssertTrue(base.x.isFinite, "\(kind) x")
            XCTAssertTrue(base.y.isFinite, "\(kind) y")
            XCTAssertTrue((base.scale ?? 0).isFinite, "\(kind) scale")
            XCTAssertTrue((base.rotation ?? 0).isFinite, "\(kind) rotation")
        }
    }
}

final class StoryFeedNormalizerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testMergesDuplicatePublisherGroupsAndStoryIds() {
        let first = group(
            type: "Channel",
            id: "publisher-1",
            stories: [story(id: "story-1"), story(id: "story-1")]
        )
        let second = group(
            type: " channel ",
            id: "publisher-1",
            stories: [story(id: "story-2", seen: true)]
        )

        let normalized = StoryFeedNormalizer.normalize([first, second], now: now)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].stories.map(\.id), ["story-1", "story-2"])
        XCTAssertTrue(normalized[0].hasUnseen)
    }

    func testDropsExpiredEmptyAndMalformedEntries() {
        let expired = story(id: "expired", expiresAt: now.addingTimeInterval(-1))
        let malformed = story(id: " ", expiresAt: now.addingTimeInterval(60))
        let emptyPublisher = group(type: "channel", id: " ", stories: [story(id: "hidden")])
        let valid = group(type: "show", id: "show-1", stories: [
            expired,
            malformed,
            story(id: "active", expiresAt: now.addingTimeInterval(60), seen: true)
        ])

        let normalized = StoryFeedNormalizer.normalize([emptyPublisher, valid], now: now)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].stories.map(\.id), ["active"])
        XCTAssertFalse(normalized[0].hasUnseen)
    }

    func testPreservesLocallySeenStateAcrossStaleRefresh() {
        let staleServerGroup = group(
            type: "channel",
            id: "publisher-1",
            stories: [story(id: "viewed-locally", seen: false)]
        )

        let normalized = StoryFeedNormalizer.normalize(
            [staleServerGroup],
            now: now,
            preservingSeenStoryIds: ["viewed-locally"]
        )

        XCTAssertTrue(normalized[0].stories[0].seen)
        XCTAssertFalse(normalized[0].hasUnseen)
    }

    private func group(type: String, id: String, stories: [StoryItem]) -> StoryGroup {
        StoryGroup(
            publisherType: type,
            publisherId: id,
            publisherName: "Publisher",
            publisherImageUrl: nil,
            stories: stories,
            hasUnseen: false
        )
    }

    private func story(
        id: String,
        expiresAt: Date? = nil,
        seen: Bool = false
    ) -> StoryItem {
        StoryItem(
            id: id,
            mediaUrl: "https://example.com/\(id).jpg",
            mediaType: "image",
            duration: 5,
            caption: nil,
            ctaLabel: nil,
            ctaUrl: nil,
            expiresAt: expiresAt ?? now.addingTimeInterval(60),
            createdAt: now,
            viewCount: 0,
            seen: seen
        )
    }
}

final class StoryMediaCacheValidationTests: XCTestCase {
    func testAcceptsOnlySuccessfulHTTPResponses() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/story.mp4"))
        let success = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)
        )
        let notFound = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
        )

        XCTAssertTrue(StoryMediaCache.isSuccessfulResponse(success))
        XCTAssertFalse(StoryMediaCache.isSuccessfulResponse(notFound))
        XCTAssertFalse(StoryMediaCache.isSuccessfulResponse(nil))
    }
}

final class StoriesRequestPolicyTests: XCTestCase {
    func testRetriesOnlySafeReadRequests() {
        XCTAssertTrue(StoriesRequestPolicy.shouldRetry(method: "GET"))
        XCTAssertTrue(StoriesRequestPolicy.shouldRetry(method: " get "))
        XCTAssertFalse(StoriesRequestPolicy.shouldRetry(method: "POST"))
        XCTAssertFalse(StoriesRequestPolicy.shouldRetry(method: "DELETE"))
        XCTAssertFalse(StoriesRequestPolicy.shouldRetry(method: "PATCH"))
    }

    func testUploadURLRequiresHTTPTransportAndHost() throws {
        XCTAssertTrue(
            StoriesRequestPolicy.isAllowedUploadURL(
                try XCTUnwrap(URL(string: "https://uploads.example.com/story.mp4?signature=abc"))
            )
        )
        XCTAssertFalse(
            StoriesRequestPolicy.isAllowedUploadURL(
                try XCTUnwrap(URL(string: "file:///tmp/story.mp4"))
            )
        )
        XCTAssertFalse(
            StoriesRequestPolicy.isAllowedUploadURL(
                try XCTUnwrap(URL(string: "westreem://upload/story"))
            )
        )
    }
}

final class StoryInteractionNormalizerTests: XCTestCase {
    func testVoteCountsAreNonNegativeAndMatchOptions() {
        XCTAssertEqual(
            StoryInteractionNormalizer.votes([4, -3, 2, 99], optionCount: 3),
            [4, 0, 2]
        )
        XCTAssertEqual(
            StoryInteractionNormalizer.votes([1], optionCount: 3),
            [1, 0, 0]
        )
        XCTAssertEqual(
            StoryInteractionNormalizer.votes(nil, optionCount: 0),
            []
        )
    }

    func testOptionIndexesMustBeWithinBounds() {
        XCTAssertEqual(StoryInteractionNormalizer.optionIndex(1, optionCount: 3), 1)
        XCTAssertNil(StoryInteractionNormalizer.optionIndex(-1, optionCount: 3))
        XCTAssertNil(StoryInteractionNormalizer.optionIndex(3, optionCount: 3))
        XCTAssertNil(StoryInteractionNormalizer.optionIndex(nil, optionCount: 3))
    }
}

final class StoryTemporaryMediaTests: XCTestCase {
    func testRecognizesOnlyStoryOwnedTemporaryFiles() {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let cameraFile = temporaryRoot
            .appendingPathComponent("story-camera-123")
            .appendingPathExtension("mov")
        let libraryFile = temporaryRoot
            .appendingPathComponent("story-camera-library-456")
            .appendingPathExtension("mp4")
        let unrelatedTemporaryFile = temporaryRoot.appendingPathComponent("user-video.mov")
        let outsideTemporaryRoot = URL(fileURLWithPath: "/var/story-camera-123.mov")

        XCTAssertTrue(StoryTemporaryMedia.isOwned(cameraFile))
        XCTAssertTrue(StoryTemporaryMedia.isOwned(libraryFile))
        XCTAssertFalse(StoryTemporaryMedia.isOwned(unrelatedTemporaryFile))
        XCTAssertFalse(StoryTemporaryMedia.isOwned(outsideTemporaryRoot))
    }
}

final class StoryLocationActionTests: XCTestCase {
    func testResolvedLocationBuildsMapsURLWithCoordinates() throws {
        let url = try XCTUnwrap(
            storyLocationMapsURL(name: "Roman Theatre", latitude: 31.9516, longitude: 35.9393)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.host, "maps.apple.com")
        XCTAssertEqual(query["q"], "Roman Theatre")
        XCTAssertEqual(query["ll"], "31.9516,35.9393")
    }

    func testLegacyLocationWithoutCoordinatesStillOpensMapsSearch() throws {
        let url = try XCTUnwrap(
            storyLocationMapsURL(name: "Downtown Amman", latitude: nil, longitude: nil)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(query["q"], "Downtown Amman")
        XCTAssertNil(query["ll"])
    }

    func testInvalidCoordinatesFallBackToNameSearch() throws {
        let url = try XCTUnwrap(
            storyLocationMapsURL(name: "Amman", latitude: 200, longitude: .infinity)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertFalse((components.queryItems ?? []).contains { $0.name == "ll" })
        XCTAssertNil(storyLocationMapsURL(name: "   ", latitude: nil, longitude: nil))
    }
}

@MainActor
final class StoryLookEditingTests: XCTestCase {
    func testCameraSelectionCarriesVersionedLookIntoEditorDraft() {
        let controller = StoryCameraController()
        let preset = StoryEffectCatalog.preset(id: "cinema")

        controller.selectFilter(preset)

        XCTAssertEqual(controller.selectedFilterId, "cinema")
        XCTAssertEqual(controller.selectedEffectStack?.version, StoryEffectStack.currentVersion)
        XCTAssertEqual(controller.selectedEffectStack?.lookId, "cinema")
    }

    func testFilterIntensityPreviewClampsWithoutCreatingUndo() {
        let editor = StoryTimelineEditor(project: projectWithClip())

        editor.previewSelectedClipFilterIntensity(4)

        XCTAssertEqual(editor.selectedClip?.filterIntensity, 1)
        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.lookIntensity, 1)
        XCTAssertFalse(editor.canUndo)
    }

    func testLegacyClipWithoutEffectStackStillDecodes() throws {
        let clip = try XCTUnwrap(projectWithClip().tracks.videoClips.first)
        let encoded = try JSONEncoder().encode(clip)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "effectStack")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VideoClip.self, from: legacyData)

        XCTAssertNil(decoded.effectStack)
        XCTAssertEqual(decoded.resolvedEffectStack.version, 0)
        XCTAssertEqual(decoded.resolvedEffectStack.lookId, decoded.filterId)
        XCTAssertEqual(decoded.resolvedEffectStack.lookIntensity, decoded.filterIntensity)
        XCTAssertEqual(decoded.resolvedEffectStack.beauty, .off)
    }

    func testBeautyPreviewUsesVersionedEffectStackAndUndoRestoresClip() async throws {
        let editor = StoryTimelineEditor(project: projectWithClip())
        let original = try XCTUnwrap(editor.selectedClip)

        editor.previewSelectedClipBeauty(.natural)
        await editor.commitSelectedClipLook(baselineClip: original)

        XCTAssertEqual(editor.selectedClip?.effectStack?.version, StoryEffectStack.currentVersion)
        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.beauty, .natural)
        XCTAssertTrue(editor.canUndo)

        await editor.undo()
        XCTAssertEqual(editor.selectedClip, original)
    }

    func testCreativeEffectSelectionAndIntensityAreClamped() {
        let editor = StoryTimelineEditor(project: projectWithClip())

        editor.previewSelectedClipCreativeEffect(.pixel, intensity: 4)

        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.creativeEffects, [.pixel])
        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.creativeEffectIntensity, 1)

        editor.previewSelectedClipCreativeEffect(.none)
        XCTAssertTrue(editor.selectedClip?.resolvedEffectStack.creativeEffects.isEmpty == true)
    }

    func testCreativeEffectCatalogHasUniqueStableIdentifiers() {
        let ids = StoryCreativeEffectCatalog.presets.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, StoryRenderEffect.none.rawValue)
        XCTAssertTrue(ids.contains(StoryRenderEffect.glow.rawValue))
        XCTAssertTrue(ids.contains(StoryRenderEffect.kaleidoscope.rawValue))
    }

    func testTimelineEffectIsDeterministicAtSameTimestamp() throws {
        var clip = try XCTUnwrap(projectWithClip().tracks.videoClips.first)
        var stack = StoryEffectStack.none
        stack.creativeEffects = [.lightLeak]
        clip.effectStack = stack
        let source = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let canvas = CanvasSpec(
            width: 64,
            height: 64,
            fps: 30,
            backgroundColor: RGBAColor(r: 0, g: 0, b: 0, a: 1)
        )
        let graph = StoryEffectGraph()

        let first = graph.render(
            sourceImage: source,
            time: CMTime(seconds: 1.25, preferredTimescale: 600),
            clip: clip,
            overlays: [],
            canvas: canvas,
            useMetalPetal: false
        )
        let second = graph.render(
            sourceImage: source,
            time: CMTime(seconds: 1.25, preferredTimescale: 600),
            clip: clip,
            overlays: [],
            canvas: canvas,
            useMetalPetal: false
        )

        XCTAssertEqual(try rgbaBytes(first), try rgbaBytes(second))
    }

    func testClipScalePreviewClampsAndCommitsAsUndoableEdit() async throws {
        let editor = StoryTimelineEditor(project: projectWithClip())
        let original = try XCTUnwrap(editor.selectedClip)
        var enlarged = original.transform
        enlarged.scale = 20
        enlarged.rotation = .pi / 4

        editor.previewSelectedClipTransform(enlarged)
        XCTAssertEqual(editor.selectedClip?.transform.scale, 4)
        XCTAssertEqual(editor.selectedClip?.transform.rotation, .pi / 4)
        XCTAssertFalse(editor.canUndo)

        await editor.commitSelectedClipTransform(
            try XCTUnwrap(editor.selectedClip).transform,
            baselineClip: original
        )
        XCTAssertTrue(editor.canUndo)

        await editor.undo()
        XCTAssertEqual(editor.selectedClip, original)
    }

    func testBeautyChangesFrameWhenFaceLandmarksAreUnavailable() throws {
        var originalClip = try XCTUnwrap(projectWithClip().tracks.videoClips.first)
        originalClip.effectStack = StoryEffectStack.none
        var editedClip = originalClip
        var beautyStack = StoryEffectStack.none
        beautyStack.beauty = .natural
        editedClip.effectStack = beautyStack
        let source = CIFilter(
            name: "CICheckerboardGenerator",
            parameters: [
                "inputColor0": CIColor(red: 0.72, green: 0.48, blue: 0.38),
                "inputColor1": CIColor(red: 0.40, green: 0.22, blue: 0.18),
                "inputWidth": 5,
                "inputSharpness": 0.7
            ]
        )!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let canvas = CanvasSpec(
            width: 64,
            height: 64,
            fps: 30,
            backgroundColor: RGBAColor(r: 0, g: 0, b: 0, a: 1)
        )
        let graph = StoryEffectGraph()

        let original = graph.render(
            sourceImage: source,
            time: .zero,
            clip: originalClip,
            overlays: [],
            canvas: canvas,
            useMetalPetal: false
        )
        let edited = graph.render(
            sourceImage: source,
            time: .zero,
            clip: editedClip,
            overlays: [],
            canvas: canvas,
            useMetalPetal: false
        )

        XCTAssertNotEqual(try rgbaBytes(original), try rgbaBytes(edited))
    }

    func testEffectStackDecodesBeforeCreativeIntensityWasAdded() throws {
        let stack = StoryEffectStack(
            version: 1,
            lookId: "cinema",
            lookIntensity: 0.7,
            beauty: .natural,
            creativeEffects: [.clarify]
        )
        let encoded = try JSONEncoder().encode(stack)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "creativeEffectIntensity")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StoryEffectStack.self, from: data)

        XCTAssertEqual(decoded.creativeEffectIntensity, 1)
        XCTAssertEqual(decoded.creativeEffects, [.clarify])
    }

    func testLegacyBeautySettingsDecodeWithAdvancedControlsOff() throws {
        let legacy: [String: Any] = [
            "intensity": 0.6,
            "skinSmoothing": 0.4,
            "skinTone": 0.1,
            "brightness": 0.08
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode(StoryBeautySettings.self, from: data)

        XCTAssertEqual(decoded.eyeBrightening, 0)
        XCTAssertEqual(decoded.wrinkleReduction, 0)
        XCTAssertEqual(decoded.skinGlow, 0)
        XCTAssertEqual(decoded.faceClarity, 0)
        XCTAssertEqual(decoded.underEye, 0)
        XCTAssertEqual(decoded.teethWhitening, 0)
        XCTAssertEqual(decoded.lipColor, 0)
        XCTAssertEqual(decoded.contour, 0)
    }

    func testMasterBeautySeedsVisibleControlsWhenStartingFromOff() {
        var beauty = StoryBeautySettings.off

        beauty.setMasterIntensity(1)

        XCTAssertEqual(beauty.intensity, 1)
        XCTAssertGreaterThan(beauty.skinSmoothing, 0.7)
        XCTAssertGreaterThan(beauty.wrinkleReduction, 0.6)
        XCTAssertGreaterThan(beauty.skinGlow, 0.4)
        XCTAssertGreaterThan(beauty.faceClarity, 0.3)
        XCTAssertGreaterThan(beauty.brightness, 0)
        XCTAssertGreaterThan(beauty.eyeBrightening, 0)
        XCTAssertTrue(beauty.isEnabled)
    }

    func testMasterBeautyPreservesExistingCustomControls() {
        var beauty = StoryBeautySettings.off
        beauty.skinSmoothing = 0.2

        beauty.setMasterIntensity(0.8)

        XCTAssertEqual(beauty.intensity, 0.8)
        XCTAssertEqual(beauty.skinSmoothing, 0.2)
        XCTAssertEqual(beauty.brightness, 0)
    }

    func testLookSessionCommitsFilterAndAdjustmentsAsOneUndoableEdit() async {
        let project = projectWithClip()
        let editor = StoryTimelineEditor(project: project)
        let original = try! XCTUnwrap(editor.selectedClip)
        let preset = StoryEffectCatalog.preset(id: "cinema")

        editor.previewEffectPreset(preset)
        editor.previewSelectedClipFilterIntensity(0.62)
        var customized = preset.adjustments
        customized.brightness = 0.12
        editor.previewSelectedClipAdjustments(customized)
        await editor.commitSelectedClipLook(baselineClip: original)

        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.selectedClip?.filterId, "cinema")
        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.version, StoryEffectStack.currentVersion)
        XCTAssertEqual(try! XCTUnwrap(editor.selectedClip?.filterIntensity), 0.62, accuracy: 0.001)
        XCTAssertEqual(editor.selectedClip?.resolvedEffectStack.lookId, "cinema")
        XCTAssertEqual(try! XCTUnwrap(editor.selectedClip?.resolvedEffectStack.lookIntensity), 0.62, accuracy: 0.001)
        XCTAssertEqual(try! XCTUnwrap(editor.selectedClip?.adjustments.brightness), 0.12, accuracy: 0.001)

        await editor.undo()

        XCTAssertEqual(editor.selectedClip, original)
        XCTAssertFalse(editor.canUndo)
    }

    func testUnchangedLookSessionDoesNotCreateUndo() async {
        let project = projectWithClip()
        let editor = StoryTimelineEditor(project: project)
        let original = try! XCTUnwrap(editor.selectedClip)

        await editor.commitSelectedClipLook(baselineClip: original)

        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.selectedClip, original)
    }

    private func projectWithClip() -> Project {
        var project = Project.storyDraft(title: "Look test", destination: nil)
        let asset = AssetRef.make(
            kind: .image,
            relativePath: "media/source.jpg",
            naturalWidth: 1080,
            naturalHeight: 1920,
            nominalFrameRate: 0,
            durationSeconds: 5
        )
        try! project.addStoryClip(.storyClip(assetRef: asset, durationSeconds: 5))
        return project
    }

    private func rgbaBytes(_ image: CIImage) throws -> [UInt8] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        CIContext(options: [.cacheIntermediates: false]).render(
            image,
            toBitmap: &bytes,
            rowBytes: width * 4,
            bounds: image.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        return bytes
    }
}
