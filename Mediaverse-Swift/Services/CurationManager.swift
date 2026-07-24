import Foundation

@MainActor
final class CurationManager {
    static let shared = CurationManager()

    private struct PageEntry {
        let page: AssembledPage
        let checkedAt: Date
    }

    private let ttl: TimeInterval = 60
    private var pageCache: [String: PageEntry] = [:]

    func cachedPage(key: String, section: String? = nil, allowExpired: Bool = false) -> AssembledPage? {
        let cacheKey = Self.cacheKey(pageKey: key, section: section)
        guard let entry = pageCache[cacheKey] else { return nil }
        guard allowExpired || Date().timeIntervalSince(entry.checkedAt) < ttl else { return nil }
        return entry.page
    }

    func curatedBrowseItems(from platformItems: [PlatformBrowseItem]) async -> [PlatformBrowseItem] {
        let indexedItems = Array(platformItems.enumerated())
        let candidates = indexedItems.compactMap { index, item -> (Int, PlatformBrowseItem, String)? in
            guard let key = Self.pageKey(for: item.id) else { return nil }
            return (index, item, key)
        }
        guard !candidates.isEmpty else { return platformItems }

        var curatedIndexes = Set<Int>()
        var completedChecks = 0
        let uncachedCandidates = candidates.filter { index, _, key in
            guard let page = cachedPage(key: key) else { return true }
            completedChecks += 1
            if page.hasCurationSurface { curatedIndexes.insert(index) }
            return false
        }

        await withTaskGroup(of: (Int, Bool, Bool).self) { group in
            for (index, _, key) in uncachedCandidates {
                group.addTask {
                    do {
                        let page = try await APIClient.shared.fetchCurationPage(key: key)
                        await MainActor.run {
                            self.store(page, key: key)
                        }
                        return (index, true, page.hasCurationSurface)
                    } catch {
                        return (index, false, false)
                    }
                }
            }

            for await (index, completed, hasContent) in group {
                if completed { completedChecks += 1 }
                if hasContent { curatedIndexes.insert(index) }
            }
        }

        // If every curation check failed, keep the platform list as a resilience fallback.
        // Once at least one curation page answers, curation filters only curation-backed tabs;
        // non-curated platform tabs such as Following and Collections remain visible.
        guard completedChecks > 0 else { return platformItems }
        return indexedItems.compactMap { index, item in
            Self.pageKey(for: item.id) == nil || curatedIndexes.contains(index) ? item : nil
        }
    }

    func fetchPage(key: String, section: String? = nil) async throws -> AssembledPage {
        let cacheKey = Self.cacheKey(pageKey: key, section: section)
        if let entry = pageCache[cacheKey], Date().timeIntervalSince(entry.checkedAt) < ttl {
            return entry.page
        }

        let page = try await APIClient.shared.fetchCurationPage(key: key, section: section)
        store(page, key: key, section: section)
        return page
    }

    private func store(_ page: AssembledPage, key: String, section: String? = nil) {
        let entry = PageEntry(page: page, checkedAt: Date())
        pageCache[Self.cacheKey(pageKey: key, section: section)] = entry
        if section == nil, let defaultSection = page.sections.sorted(by: { $0.order < $1.order }).first {
            pageCache[Self.cacheKey(pageKey: key, section: defaultSection.id)] = entry
            pageCache[Self.cacheKey(pageKey: key, section: defaultSection.name)] = entry
        }
        prefetchImages(for: page, section: section)
    }

    private func prefetchImages(for page: AssembledPage, section: String?) {
        let activeListings = page.listings(forSectionID: section)
        let items = activeListings.isEmpty ? page.curationItems : activeListings.flatMap(\.items)
        let urls = items.prefix(24).compactMap { item in
            C.mediaURL(item.thumbnailUrl ?? item.coverUrl)
        }
        guard !urls.isEmpty else { return }
        Task {
            await RemoteImageCache.shared.prefetch(
                urls: urls,
                targetPixelSize: CGSize(width: 360, height: 540),
                limit: 24
            )
        }
    }

    private static func cacheKey(pageKey: String, section: String?) -> String {
        if let section, !section.isEmpty { return "\(pageKey)#\(section)" }
        return pageKey
    }

    private static func pageKey(for browseID: String) -> String? {
        switch PlatformBrowseItem.normalizedId(browseID) {
        case "shows": return "shows"
        case "videos": return "videos"
        case "movies": return "movies"
        case "microdramas": return "microdramas"
        case "channels": return "channels"
        default: return nil
        }
    }
}
