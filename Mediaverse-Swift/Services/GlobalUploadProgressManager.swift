import Foundation
import SwiftUI

@MainActor
final class GlobalUploadProgressManager: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case active
            case complete
            case failed
        }

        let id: UUID
        var title: String
        var detail: String
        var progress: Double
        var state: State
    }

    static let shared = GlobalUploadProgressManager()

    @Published private(set) var item: Item?

    private var hideTask: Task<Void, Never>?

    private init() {}

    @discardableResult
    func begin(title: String, detail: String, progress: Double = 0) -> UUID {
        hideTask?.cancel()
        let id = UUID()
        item = Item(
            id: id,
            title: title,
            detail: detail,
            progress: min(max(progress, 0), 1),
            state: .active
        )
        return id
    }

    func update(id: UUID, title: String? = nil, detail: String? = nil, progress: Double? = nil) {
        guard var current = item, current.id == id else { return }
        if let title { current.title = title }
        if let detail { current.detail = detail }
        if let progress { current.progress = min(max(progress, 0), 1) }
        current.state = .active
        item = current
    }

    func complete(id: UUID, title: String, detail: String) {
        guard var current = item, current.id == id else { return }
        current.title = title
        current.detail = detail
        current.progress = 1
        current.state = .complete
        item = current
        scheduleHide()
    }

    func fail(id: UUID, title: String, detail: String) {
        guard var current = item, current.id == id else { return }
        current.title = title
        current.detail = detail
        current.state = .failed
        item = current
        scheduleHide(after: 6_000_000_000)
    }

    func dismiss() {
        hideTask?.cancel()
        item = nil
    }

    private func scheduleHide(after delay: UInt64 = 4_000_000_000) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            item = nil
        }
    }
}
