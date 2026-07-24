import Foundation

@MainActor
enum UploadOptionsCache {
    private(set) static var contexts: UploadContextsResponse?
    private static var refreshTask: Task<UploadContextsResponse?, Never>?
    private static var refreshTaskID: UUID?
    private static var contextCookieValue: String?

    static func warmContexts() {
        let key = SessionStorage.activeContextCookieValue
        if contextCookieValue != key {
            clear()
            contextCookieValue = key
        }
        guard refreshTask == nil, contexts == nil else { return }
        let requestID = UUID()
        refreshTaskID = requestID
        refreshTask = Task {
            do {
                let response = try await APIClient.shared.fetchUploadContexts()
                await MainActor.run {
                    guard refreshTaskID == requestID,
                          SessionStorage.activeContextCookieValue == key else { return }
                    contexts = response
                    contextCookieValue = key
                    refreshTask = nil
                    refreshTaskID = nil
                }
                return response
            } catch {
                await MainActor.run {
                    guard refreshTaskID == requestID else { return }
                    refreshTask = nil
                    refreshTaskID = nil
                }
                return nil
            }
        }
    }

    static func refreshContexts() async throws -> UploadContextsResponse {
        let key = SessionStorage.activeContextCookieValue
        if contextCookieValue != key {
            clear()
            contextCookieValue = key
        }
        if let task = refreshTask, let response = await task.value {
            guard contextCookieValue == key,
                  SessionStorage.activeContextCookieValue == key else {
                return try await refreshContexts()
            }
            contexts = response
            contextCookieValue = key
            return response
        }
        let response = try await APIClient.shared.fetchUploadContexts()
        guard SessionStorage.activeContextCookieValue == key else {
            return try await refreshContexts()
        }
        contexts = response
        contextCookieValue = key
        return response
    }

    static func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        contexts = nil
        contextCookieValue = nil
    }
}
