import Foundation

struct CacheMetricSnapshot: Sendable {
    let namespace: String
    let hits: Int
    let misses: Int
    let stores: Int
    let evictions: Int
    let errors: Int
    let bytesStored: UInt64

    var requests: Int { hits + misses }
    var hitRate: Double {
        guard requests > 0 else { return 0 }
        return Double(hits) / Double(requests)
    }
}

struct PerformanceMetricSnapshot: Sendable {
    let namespace: String
    let samples: Int
    let totalDuration: TimeInterval
    let maximumDuration: TimeInterval

    var averageDuration: TimeInterval {
        guard samples > 0 else { return 0 }
        return totalDuration / Double(samples)
    }
}

final class CacheMetrics: @unchecked Sendable {
    static let shared = CacheMetrics()

    private struct Counters {
        var hits = 0
        var misses = 0
        var stores = 0
        var evictions = 0
        var errors = 0
        var bytesStored: UInt64 = 0
    }

    private struct TimingCounters {
        var samples = 0
        var totalDuration: TimeInterval = 0
        var maximumDuration: TimeInterval = 0
    }

    private let lock = NSLock()
    private var countersByNamespace = [String: Counters]()
    private var timingsByNamespace = [String: TimingCounters]()

    func recordHit(_ namespace: String) {
        update(namespace) { $0.hits += 1 }
    }

    func recordMiss(_ namespace: String) {
        update(namespace) { $0.misses += 1 }
    }

    func recordStore(_ namespace: String, bytes: UInt64 = 0) {
        update(namespace) {
            $0.stores += 1
            $0.bytesStored += bytes
        }
    }

    func recordEviction(_ namespace: String, count: Int = 1) {
        update(namespace) { $0.evictions += count }
    }

    func recordError(_ namespace: String) {
        update(namespace) { $0.errors += 1 }
    }

    func snapshots() -> [CacheMetricSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return countersByNamespace
            .map { namespace, counters in
                CacheMetricSnapshot(
                    namespace: namespace,
                    hits: counters.hits,
                    misses: counters.misses,
                    stores: counters.stores,
                    evictions: counters.evictions,
                    errors: counters.errors,
                    bytesStored: counters.bytesStored
                )
            }
            .sorted { $0.namespace < $1.namespace }
    }

    func recordDuration(_ namespace: String, startedAt: Date) {
        recordDuration(namespace, duration: max(0, Date().timeIntervalSince(startedAt)))
    }

    func recordDuration(_ namespace: String, duration: TimeInterval) {
        lock.lock()
        var counters = timingsByNamespace[namespace] ?? TimingCounters()
        counters.samples += 1
        counters.totalDuration += max(0, duration)
        counters.maximumDuration = max(counters.maximumDuration, duration)
        timingsByNamespace[namespace] = counters
        lock.unlock()
    }

    func performanceSnapshots() -> [PerformanceMetricSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return timingsByNamespace
            .map { namespace, counters in
                PerformanceMetricSnapshot(
                    namespace: namespace,
                    samples: counters.samples,
                    totalDuration: counters.totalDuration,
                    maximumDuration: counters.maximumDuration
                )
            }
            .sorted { $0.namespace < $1.namespace }
    }

    func reset() {
        lock.lock()
        countersByNamespace.removeAll()
        timingsByNamespace.removeAll()
        lock.unlock()
    }

    func debugSummary() -> String {
        let cacheSummary = snapshots()
            .map { snapshot in
                let percent = Int((snapshot.hitRate * 100).rounded())
                return "\(snapshot.namespace): hitRate=\(percent)% hits=\(snapshot.hits) misses=\(snapshot.misses) stores=\(snapshot.stores) evictions=\(snapshot.evictions) errors=\(snapshot.errors) bytes=\(snapshot.bytesStored)"
            }
            .joined(separator: "\n")
        let performanceSummary = performanceSnapshots()
            .map { snapshot in
                let averageMS = Int((snapshot.averageDuration * 1_000).rounded())
                let maximumMS = Int((snapshot.maximumDuration * 1_000).rounded())
                return "\(snapshot.namespace): samples=\(snapshot.samples) average=\(averageMS)ms maximum=\(maximumMS)ms"
            }
            .joined(separator: "\n")
        return [cacheSummary, performanceSummary]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func update(_ namespace: String, _ mutate: (inout Counters) -> Void) {
        lock.lock()
        var counters = countersByNamespace[namespace] ?? Counters()
        mutate(&counters)
        countersByNamespace[namespace] = counters
        lock.unlock()
    }
}
