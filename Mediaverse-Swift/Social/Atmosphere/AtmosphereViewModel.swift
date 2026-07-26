import Foundation

@MainActor
final class AtmosphereViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case atmosphere
        case discover
        case myVibes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .atmosphere: "The Atmosphere"
            case .discover: "Discover"
            case .myVibes: "My Vibes"
            }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var selectedTab: Tab = .atmosphere
    @Published private(set) var atmosphereItems: [AtmosphereFeedItem] = []
    @Published private(set) var discoveredRipples: [Ripple] = []
    @Published private(set) var myVibes: [VibeSummary] = []
    @Published private(set) var stateByTab: [Tab: LoadState] = [:]

    private let api: LegacySocialAPIAdapter

    init(api: LegacySocialAPIAdapter = LegacySocialAPIAdapter(transport: APIClient.shared)) {
        self.api = api
    }

    func select(_ tab: Tab) {
        selectedTab = tab
        Task { await loadIfNeeded(tab) }
    }

    func loadIfNeeded(_ tab: Tab? = nil) async {
        let tab = tab ?? selectedTab
        guard stateByTab[tab] == nil || stateByTab[tab] == .idle else { return }
        await load(tab)
    }

    func reload(_ tab: Tab? = nil) async {
        await load(tab ?? selectedTab)
    }

    private func load(_ tab: Tab) async {
        stateByTab[tab] = .loading
        do {
            switch tab {
            case .atmosphere:
                atmosphereItems = try await api.atmosphere().items
            case .discover:
                discoveredRipples = try await api.discover(mode: .forYou).posts
            case .myVibes:
                myVibes = try await api.myVibes().clubs
            }
            stateByTab[tab] = .loaded
        } catch is CancellationError {
            stateByTab[tab] = .idle
        } catch {
            stateByTab[tab] = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return "This part of The Atmosphere could not be loaded."
    }
}
