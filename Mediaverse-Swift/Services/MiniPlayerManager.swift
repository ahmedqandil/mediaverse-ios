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

    func present(player: AVPlayer, title: String, route: AppRoute) {
        item = Item(player: player, title: title, route: route)
    }

    func close() {
        item?.player.pause()
        item = nil
    }
}
