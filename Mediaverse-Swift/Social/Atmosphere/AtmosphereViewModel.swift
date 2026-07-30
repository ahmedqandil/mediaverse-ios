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
    @Published private(set) var atmosphereItems: [AtmosphereV2FeedItem] = []
    @Published private(set) var atmosphereNextCursor: String?
    @Published private(set) var isLoadingMoreAtmosphere = false
    @Published private(set) var atmospherePaginationError: String?
    @Published private(set) var discoveredRipples: [Ripple] = []
    @Published private(set) var discoverMode: SocialDiscoverMode = .forYou
    @Published private(set) var emptyDiscoverModes = Set<SocialDiscoverMode>()
    @Published private(set) var myVibes: [VibeSummary] = []
    @Published private(set) var stateByTab: [Tab: LoadState] = [:]
    @Published private(set) var curationListings: [AssembledListing] = []

    private let api: LegacySocialAPIAdapter
    private let atmosphereRepository: WestreemAtmosphereV2Repository
    private var hasLoadedCuration = false
    private var hasCheckedAffiliatedAvailability = false
    private var atmosphereGeneration = 0

    init(
        selectedTab: Tab = .atmosphere,
        api: LegacySocialAPIAdapter = LegacySocialAPIAdapter(transport: APIClient.shared),
        atmosphereRepository: WestreemAtmosphereV2Repository =
            WestreemAtmosphereV2Repository(
                transport: APIClient.shared,
                rollout: AtmoV2Rollout(localEnabled: true)
            )
    ) {
        self.selectedTab = selectedTab
        self.api = api
        self.atmosphereRepository = atmosphereRepository
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

    func selectDiscoverMode(_ mode: SocialDiscoverMode) {
        guard discoverMode != mode else { return }
        discoverMode = mode
        discoveredRipples = []
        stateByTab[.discover] = .idle
        Task { await load(.discover) }
    }

    var availableDiscoverModes: [SocialDiscoverMode] {
        SocialDiscoverMode.allCases.filter { mode in
            mode == .forYou || !emptyDiscoverModes.contains(mode)
        }
    }

    var atmosphereFeedListing: AssembledListing? {
        curationListings.first { $0.normalizedTemplateType == "atmosphere_feed" }
    }

    var beforeFeedListings: [AssembledListing] {
        let injected = Set(atmosphereFeedListing?.feedSlots?.map(\.listingId) ?? [])
        guard let index = curationListings.firstIndex(where: { $0.normalizedTemplateType == "atmosphere_feed" }) else {
            return curationListings.filter {
                $0.normalizedTemplateType != "atmosphere_feed"
                    && !injected.contains($0.listingId)
            }
        }
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

    func loadMoreAtmosphere() async {
        guard
            let cursor = atmosphereNextCursor,
            !isLoadingMoreAtmosphere,
            stateByTab[.atmosphere] == .loaded
        else { return }
        let generation = atmosphereGeneration
        isLoadingMoreAtmosphere = true
        atmospherePaginationError = nil
        defer { isLoadingMoreAtmosphere = false }
        do {
            let page = try await atmosphereRepository.page(cursor: cursor)
            guard
                generation == atmosphereGeneration,
                atmosphereNextCursor == cursor
            else { return }
            let existing = Set(atmosphereItems.map(\.id))
            atmosphereItems.append(
                contentsOf: page.items.filter { !existing.contains($0.id) }
            )
            atmosphereNextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            // Never reactivate the subscriptions/Fan Club feed. A pagination
            // failure preserves only the already-authorized v2 page.
            atmospherePaginationError =
                "More of The Atmosphere could not be loaded."
        }
    }

    private func loadCurationIfNeeded() async {
        guard !hasLoadedCuration else { return }
        hasLoadedCuration = true
        do {
            let page = try await CurationManager.shared.fetchPage(key: "atmosphere")
            curationListings = page.activeListings
            #if DEBUG
            print("[social-ui] atmosphere curation listings=\(curationListings.count)")
            #endif
        } catch {
            // Curation is presentation-only. Organic social feeds remain available.
            curationListings = []
            #if DEBUG
            print("[social-ui] atmosphere curation failed=\(String(describing: error))")
            #endif
        }
    }

    private func load(_ tab: Tab) async {
        stateByTab[tab] = .loading
        var requestedAtmosphereGeneration: Int?
        do {
            switch tab {
            case .atmosphere:
                atmosphereGeneration &+= 1
                let generation = atmosphereGeneration
                requestedAtmosphereGeneration = generation
                let page = try await atmosphereRepository.page()
                guard generation == atmosphereGeneration else { return }
                atmosphereItems = page.items
                atmosphereNextCursor = page.nextCursor
                atmospherePaginationError = nil
            case .discover:
                let requestedMode = discoverMode
                let response = try await api.discover(mode: requestedMode)
                guard requestedMode == discoverMode else { return }
                discoveredRipples = response.posts
                if response.posts.isEmpty {
                    emptyDiscoverModes.insert(requestedMode)
                } else {
                    emptyDiscoverModes.remove(requestedMode)
                }
                if requestedMode != .affiliated {
                    Task { await checkAffiliatedAvailability() }
                }
            case .myVibes:
                myVibes = try await api.myVibes().clubs
            }
            stateByTab[tab] = .loaded
            #if DEBUG
            let count: Int
            switch tab {
            case .atmosphere: count = atmosphereItems.count
            case .discover: count = discoveredRipples.count
            case .myVibes: count = myVibes.count
            }
            print("[social-ui] \(tab.rawValue) decoded=\(count)")
            #endif
        } catch is CancellationError {
            if tab == .atmosphere,
               requestedAtmosphereGeneration != atmosphereGeneration {
                return
            }
            stateByTab[tab] = .idle
        } catch {
            if tab == .atmosphere {
                guard requestedAtmosphereGeneration == atmosphereGeneration else {
                    return
                }
                atmosphereGeneration &+= 1
                // The root feed fails closed. Stale legacy or v2 data must not
                // survive a rejected authority, platform gate, or refresh.
                atmosphereItems = []
                atmosphereNextCursor = nil
                atmospherePaginationError = nil
            }
            stateByTab[tab] = .failed(Self.message(for: error))
            #if DEBUG
            print("[social-ui] \(tab.rawValue) failed=\(String(describing: error))")
            #endif
        }
    }

    private func checkAffiliatedAvailability() async {
        guard !hasCheckedAffiliatedAvailability else { return }
        hasCheckedAffiliatedAvailability = true
        do {
            let response = try await api.discover(mode: .affiliated)
            if response.posts.isEmpty {
                emptyDiscoverModes.insert(.affiliated)
            } else {
                emptyDiscoverModes.remove(.affiliated)
            }
        } catch {
            // Keep the filter available when the server cannot confirm its state.
            hasCheckedAffiliatedAvailability = false
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.localizedDescription
        }
        return "This part of The Atmosphere could not be loaded."
    }
}
