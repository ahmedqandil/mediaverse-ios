import SwiftUI
import AVKit

@MainActor
final class MiniPlayerManager: ObservableObject {
    struct Item {
        let player: AVPlayer
        let title: String
        let route: AppRoute
        let isAd: Bool
        let adPresentation: ActiveAdPresentation?
        let sourceFrame: CGRect?
        let playbackSessionId: String
        let entryContext: PlaybackEntryContext
    }

    @Published var item: Item?
    @Published private(set) var expansionAttachToken = 0
    @Published private(set) var replaceAndExpandToken = 0
    @Published private(set) var isExpansionHandoffActive = false
    private var expandedItem: Item?

    func present(player: AVPlayer, title: String, route: AppRoute, playbackSessionId: String = UUID().uuidString, entryContext: PlaybackEntryContext = .direct) {
        isExpansionHandoffActive = false
        item = Item(player: player, title: title, route: route, isAd: false, adPresentation: nil, sourceFrame: nil, playbackSessionId: playbackSessionId, entryContext: entryContext)
        player.play()
    }

    func presentAd(player: AVPlayer, title: String, route: AppRoute, presentation: ActiveAdPresentation?, playbackSessionId: String = UUID().uuidString, entryContext: PlaybackEntryContext = .direct) {
        isExpansionHandoffActive = false
        item = Item(player: player, title: title, route: route, isAd: true, adPresentation: presentation, sourceFrame: nil, playbackSessionId: playbackSessionId, entryContext: entryContext)
        player.play()
    }

    func replaceAndExpand(player: AVPlayer, title: String, route: AppRoute, sourceFrame: CGRect? = nil, entrySurface: PlaybackEntrySurface) {
        item?.player.pause()
        expandedItem?.player.pause()
        isExpansionHandoffActive = false
        expandedItem = nil
        let seconds = player.currentTime().seconds
        item = Item(
            player: player,
            title: title,
            route: route,
            isAd: false,
            adPresentation: nil,
            sourceFrame: sourceFrame,
            playbackSessionId: UUID().uuidString,
            entryContext: PlaybackEntryContext(
                surface: entrySurface,
                mode: .autoplayPreview,
                contentStartSec: seconds.isFinite ? max(0, seconds) : 0,
                previewSessionId: UUID().uuidString
            )
        )
        player.playImmediately(atRate: 1)
        replaceAndExpandToken += 1
    }

    func beginExpansionHandoff() {
        isExpansionHandoffActive = true
    }

    func prepareForExpansion() {
        expandedItem = item
        item = nil
    }

    func takeExpandedItem(for route: AppRoute) -> Item? {
        guard expandedItem?.route == route else { return nil }
        let item = expandedItem
        expandedItem = nil
        return item
    }

    func takeExpandedPlayer(for route: AppRoute) -> AVPlayer? {
        takeExpandedItem(for: route)?.player
    }

    func markExpandedPlayerAttached() {
        guard isExpansionHandoffActive else { return }
        expansionAttachToken += 1
    }

    func finishExpansionHandoff() {
        isExpansionHandoffActive = false
        expandedItem = nil
    }

    func close() {
        item?.player.pause()
        expandedItem?.player.pause()
        item = nil
        expandedItem = nil
        isExpansionHandoffActive = false
    }
}
