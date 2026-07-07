import Foundation

actor StoriesAPIClient {
    static let shared = StoriesAPIClient()

    private let session: URLSession
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(
        session: URLSession = StoriesAPIClient.makeSession(),
        baseURL: URL = URL(string: C.baseURL) ?? URL(string: "https://www.westreem.com")!
    ) {
        self.session = session
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    func fetchGroups() async throws -> [StoryGroup] {
        try await send("/api/stories", method: "GET", body: Optional<Data>.none, authenticated: false)
    }

    func markViewed(storyId: String) async throws {
        struct Response: Decodable { let ok: Bool? }
        let _: Response = try await send("/api/stories/\(storyId)/view", method: "POST", body: Data(), authenticated: true)
    }

    func getUploadUrl(mimeType: String) async throws -> UploadUrlResponse {
        let data = try encoder.encode(UploadUrlRequest(mimeType: mimeType))
        return try await send("/api/stories/upload-url", method: "POST", body: data, authenticated: true)
    }

    func uploadMedia(to url: URL, data: Data, mimeType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-upload-\(UUID().uuidString)")
        try data.write(to: fileURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try await uploadMedia(to: url, fileURL: fileURL, mimeType: mimeType, onProgress: onProgress)
    }

    /// Uploads the media file and returns the server-assigned mediaUrl if the response body
    /// contains one (Vercel Blob direct-upload mode), or nil when using a presigned PUT to R2/CF.
    func uploadMedia(to url: URL, fileURL: URL, mimeType: String, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        // Resolve relative URLs against the base URL (used by the Blob fallback path)
        let resolvedURL = url.scheme == nil || url.scheme!.isEmpty
            ? URL(string: url.absoluteString, relativeTo: baseURL)!
            : url

        var request = URLRequest(url: resolvedURL)
        let isVideo = mimeType.lowercased().hasPrefix("video/")
        request.httpMethod = isVideo ? "POST" : "PUT"

        let uploadFileURL: URL
        if isVideo {
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadFileURL = try multipartBodyFile(fileURL: fileURL, mimeType: mimeType, boundary: boundary)
        } else {
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            uploadFileURL = fileURL
        }
        defer {
            if isVideo { try? FileManager.default.removeItem(at: uploadFileURL) }
        }

        // Attach auth headers when uploading to our own API (relative URL or westreem.com host)
        let isOwnAPI = resolvedURL.host == baseURL.host || resolvedURL.host == nil
        if isOwnAPI, let token = SessionStorage.token {
            request.setValue("next-auth.session-token=\(token); __Secure-next-auth.session-token=\(token)", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        await MainActor.run { onProgress(0) }
        let progressDelegate = StoriesUploadProgressDelegate(onProgress: onProgress)
        let (responseData, response) = try await session.upload(for: request, fromFile: uploadFileURL, delegate: progressDelegate)
        try validate(response, data: responseData)
        await MainActor.run { onProgress(1) }

        // If the server returned { "mediaUrl": "..." } (Vercel Blob fallback), use it
        if let mediaResponse = try? JSONDecoder().decode(UploadMediaResponse.self, from: responseData),
           !mediaResponse.mediaUrl.isEmpty {
            return mediaResponse.mediaUrl
        }
        return nil
    }

    func createStory(_ request: CreateStoryRequest) async throws -> StoryItem {
        let data = try encoder.encode(request)
        return try await send("/api/stories", method: "POST", body: data, authenticated: true)
    }

    func deleteStory(id: String) async throws {
        struct Response: Decodable { let success: Bool }
        let _: Response = try await send("/api/stories/\(id)", method: "DELETE", body: Optional<Data>.none, authenticated: true)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?, authenticated: Bool) async throws -> T {
        try await send(path, method: method, body: body, authenticated: authenticated, retrying: true)
    }

    private func send<T: Decodable>(_ path: String, method: String, body: Data?, authenticated: Bool, retrying: Bool) async throws -> T {
        let responseData = try await data(path, method: method, body: body, authenticated: authenticated, retrying: retrying)
        do {
            return try decoder.decode(T.self, from: responseData)
        } catch {
            throw StoriesError.decodingFailed
        }
    }

    private func data(_ path: String, method: String, body: Data?, authenticated: Bool, retrying: Bool) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw StoriesError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil && method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if authenticated, let token = SessionStorage.token {
            request.setValue("next-auth.session-token=\(token); __Secure-next-auth.session-token=\(token)", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (responseData, response) = try await session.data(for: request)
        do {
            try validate(response, data: responseData)
            return responseData
        } catch StoriesError.serverUnavailable where retrying {
            try await Task.sleep(nanoseconds: 350_000_000)
            return try await data(path, method: method, body: body, authenticated: authenticated, retrying: false)
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let serverMessage = serverErrorMessage(from: data)
        switch http.statusCode {
        case 401:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notSignedIn
        case 403:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notAllowed
        case 404:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.notFound
        case 500..<600:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.serverUnavailable(statusCode: http.statusCode)
        default:
            throw serverMessage.map { StoriesError.serverMessage($0) } ?? StoriesError.http(http.statusCode)
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error", "detail", "reason"] {
                if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            if let errors = object["errors"] as? [String], let first = errors.first, !first.isEmpty {
                return first
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return nil
    }

    private func multipartBodyFile(fileURL: URL, mimeType: String, boundary: String) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-upload-body-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let writer = try FileHandle(forWritingTo: outputURL)
        defer { try? writer.close() }

        try writer.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try writer.write(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"story.mp4\"\r\n".utf8))
        try writer.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))

        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        while true {
            let chunk = try reader.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
        }

        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return outputURL
    }
}

private final class StoriesUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        Task { @MainActor [onProgress] in
            onProgress(progress)
        }
    }
}

enum StoriesError: LocalizedError {
    case badURL
    case notSignedIn
    case notAllowed
    case notFound
    case serverUnavailable(statusCode: Int? = nil)
    case decodingFailed
    case http(Int)
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The story endpoint is not configured correctly."
        case .notSignedIn:
            return "Sign in to use stories."
        case .notAllowed:
            return "You do not have permission to manage this story."
        case .notFound:
            return "This story is no longer available."
        case .serverUnavailable(let statusCode):
            if let statusCode {
                return "Stories are temporarily unavailable. Server returned HTTP \(statusCode)."
            }
            return "Stories are temporarily unavailable."
        case .decodingFailed:
            return "Stories returned an unexpected response."
        case .http(let code):
            return "Stories request failed with HTTP \(code)."
        case .serverMessage(let message):
            return message
        }
    }
}
