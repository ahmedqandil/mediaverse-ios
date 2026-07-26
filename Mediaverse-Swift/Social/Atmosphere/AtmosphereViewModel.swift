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
    @Published private(set) var curationListings: [AssembledListing] = []

    private let api: LegacySocialAPIAdapter
    private var hasLoadedCuration = false

    init(api: LegacySocialAPIAdapter = LegacySocialAPIAdapter(transport: APIClient.shared)) {
        self.api = api
    }

    func select(_ tab: Tab) {
        selectedTab = tab
        Task { await loadIfNeeded(tab) }
    }

    func loadIfNeeded(_ tab: Tab? = nil) async {
        let tab = tab ?? selectedTab
        await loadCurationIfNeeded()
        guard stateByTab[tab] == nil || stateByTab[tab] == .idle else { return }
        await load(tab)
    }

    func reload(_ tab: Tab? = nil) async {
        await load(tab ?? selectedTab)
    }

    func prepend(_ ripple: Ripple) {
        atmosphereItems.insert(.ripple(ripple), at: 0)
    }

    var atmosphereFeedListing: AssembledListing? {
        curationListings.first { $0.normalizedTemplateType == "atmosphere_feed" }
    }

    var beforeFeedListings: [AssembledListing] {
        guard let index = curationListings.firstIndex(where: { $0.normalizedTemplateType == "atmosphere_feed" }) else {
            return []
        }
        let injected = Set(atmosphereFeedListing?.feedSlots?.map(\.listingId) ?? [])
        return curationListings[..<index].filter { !injected.contains($0.listingId) }
    }

    var afterFeedListings: [AssembledListing] {
        guard let index = curationListings.firstIndex(where: { $0.normalizedTemplateType == "atmosphere_feed" }) else {
            return []
        }
        let injected = Set(atmosphereFeedListing?.feedSlots?.map(\.listingId) ?? [])
        return curationListings.suffix(from: curationListings.index(after: index))
            .filter { !injected.contains($0.listingId) }
    }

    var inlineListings: [AssembledListing] {
        guard let feed = atmosphereFeedListing else { return [] }
        return Array((feed.feedSlots ?? []).prefix(max(0, feed.feedConfig?.mobileCount ?? 2)))
    }

    var inlineEvery: Int {
        guard atmosphereFeedListing != nil else { return 0 }
        return max(1, atmosphereFeedListing?.feedConfig?.mobileEvery ?? 5)
    }

    private func loadCurationIfNeeded() async {
        guard !hasLoadedCuration else { return }
        hasLoadedCuration = true
        do {
            let page = try await CurationManager.shared.fetchPage(key: "atmosphere")
            curationListings = page.activeListings
        } catch {
            // Curation is presentation-only. Organic social feeds remain available.
            curationListings = []
        }
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
