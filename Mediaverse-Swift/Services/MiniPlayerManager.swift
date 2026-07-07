import SwiftUI
import AVKit

@MainActor
final class MiniPlayerManager: ObservableObject {
    struct Item {
        let player: AVPlayer
        let title: String
        let route: AppRoute
    }

    @Published var item: Item?
    @Published private(set) var expansionAttachToken = 0
    @Published private(set) var replaceAndExpandToken = 0
    @Published private(set) var isExpansionHandoffActive = false
    private var expandedItem: Item?

    func present(player: AVPlayer, title: String, route: AppRoute) {
        isExpansionHandoffActive = false
        item = Item(player: player, title: title, route: route)
    }

    func replaceAndExpand(player: AVPlayer, title: String, route: AppRoute) {
        item?.player.pause()
        expandedItem?.player.pause()
        isExpansionHandoffActive = false
        expandedItem = nil
        item = Item(player: player, title: title, route: route)
        player.play()
        replaceAndExpandToken += 1
    }

    func beginExpansionHandoff() {
        isExpansionHandoffActive = true
    }

    func prepareForExpansion() {
        expandedItem = item
        item = nil
    }

    func takeExpandedPlayer(for route: AppRoute) -> AVPlayer? {
        guard expandedItem?.route == route else { return nil }
        let player = expandedItem?.player
        expandedItem = nil
        return player
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
        item = nil
        expandedItem = nil
        isExpansionHandoffActive = false
    }
}
