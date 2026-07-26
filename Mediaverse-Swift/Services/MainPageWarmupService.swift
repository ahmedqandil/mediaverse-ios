import Foundation

actor MainPageWarmupService {
    static let shared = MainPageWarmupService()

    private var warmupTask: Task<Void, Never>?
    private var warmupID: UUID?
    private var lastWarmupAt: Date?
    private let cooldown: TimeInterval = 90

    func prewarm(isAuthenticated: Bool, force: Bool = false) {
        if !force, let lastWarmupAt, Date().timeIntervalSince(lastWarmupAt) < cooldown {
            return
        }
        if force {
            warmupTask?.cancel()
            warmupTask = nil
        }
        guard warmupTask == nil else { return }

        let id = UUID()
        warmupID = id
        warmupTask = Task(priority: .utility) {
            await runWarmup(isAuthenticated: isAuthenticated)
            finishWarmup(id: id, completed: !Task.isCancelled)
        }
    }

    func cancelWarmup() {
        warmupTask?.cancel()
        warmupTask = nil
        warmupID = nil
    }

    private func finishWarmup(id: UUID, completed: Bool) {
        guard warmupID == id else { return }
        if completed {
            lastWarmupAt = Date()
        }
        warmupTask = nil
        warmupID = nil
    }

    private func runWarmup(isAuthenticated: Bool) async {
        let warmupStartedAt = Date()
        defer { CacheMetrics.shared.recordDuration("startup.warmup.total", startedAt: warmupStartedAt) }

        await runBatch([
            { _ = try await APIClient.shared.fetchPlatformConfig() },
            { _ = try await CurationManager.shared.fetchPage(key: "atmosphere") },
            { _ = try await CurationManager.shared.fetchPage(key: "shorts") },
            { _ = try await APIClient.shared.fetchFeed() }
        ])

        guard !Task.isCancelled else { return }
        await Task.yield()

        await runBatch([
            { _ = try await CurationManager.shared.fetchPage(key: "shows") },
            { _ = try await CurationManager.shared.fetchPage(key: "videos") },
            { _ = try await CurationManager.shared.fetchPage(key: "movies") }
        ])

        guard !Task.isCancelled else { return }
        await Task.yield()

        await runBatch([
            { _ = try await CurationManager.shared.fetchPage(key: "microdramas") },
            { _ = try await APIClient.shared.fetchPublicCollections() },
            { _ = try await APIClient.shared.fetchPlaylists() }
        ])

        guard isAuthenticated, !Task.isCancelled else { return }
        await Task.yield()

        await runBatch([
            { _ = try await APIClient.shared.fetchProfile() },
            { _ = try await APIClient.shared.fetchContexts() },
            { _ = try await APIClient.shared.fetchContinueWatching() }
        ])

        guard !Task.isCancelled else { return }
        await Task.yield()

        await runBatch([
            { _ = try await APIClient.shared.fetchFollowingFeed() },
            { _ = try await APIClient.shared.fetchNotificationCounts() }
        ])
    }

    private func runBatch(_ operations: [@Sendable () async throws -> Void]) async {
        let batchStartedAt = Date()
        defer { CacheMetrics.shared.recordDuration("startup.warmup.batch", startedAt: batchStartedAt) }
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask(priority: .utility) {
                    await self.ignoreFailure(operation)
                }
            }
        }
    }

    private func ignoreFailure(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            // Warmup should never block first render or surface background errors.
        }
    }
}
