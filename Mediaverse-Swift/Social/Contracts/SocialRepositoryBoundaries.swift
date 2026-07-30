import Foundation

/// Westreem-authoritative public social repository.
///
/// Associated types keep this Phase 0 seam independent from both the legacy
/// Fan Club DTOs and the future clean Atmo schema.
public protocol AtmoRepository: Sendable {
    associatedtype AtmospherePage: Sendable
    associatedtype PersonalAtmoPage: Sendable
    associatedtype PostDraft: Sendable
    associatedtype Post: Sendable

    static var authority: SocialAuthority { get }

    func atmosphere(cursor: String?) async throws -> AtmospherePage
    func personalAtmo(userID: String, cursor: String?) async throws -> PersonalAtmoPage
    func createPersonalAtmoPost(_ draft: PostDraft) async throws -> Post
    func setFollowing(userID: String, following: Bool) async throws
}

public extension AtmoRepository {
    static var authority: SocialAuthority { .westreem }
}

/// Matrix-authoritative community repository.
///
/// Implementations must write Vibe activity directly to Matrix. Westreem API
/// adapters may implement migration or projection services, but must not be
/// used as the canonical production implementation of this protocol.
public protocol VibesRepository: Sendable {
    associatedtype VibeDirectory: Sendable
    associatedtype WaveDirectory: Sendable
    associatedtype Timeline: Sendable
    associatedtype OutboundEvent: Sendable
    associatedtype SentEvent: Sendable

    static var authority: SocialAuthority { get }

    func vibes(cursor: String?) async throws -> VibeDirectory
    func waves(spaceID: String) async throws -> WaveDirectory
    func timeline(roomID: String, from token: String?) async throws -> Timeline
    func send(_ event: OutboundEvent, toRoomID roomID: String) async throws -> SentEvent
}

public extension VibesRepository {
    static var authority: SocialAuthority { .matrix }
}

/// Compile-time guard used by composition roots before installing a repository.
public enum SocialRepositoryBoundary {
    public static func acceptsAtmoAuthority(_ authority: SocialAuthority) -> Bool {
        authority == .westreem
    }

    public static func acceptsVibesAuthority(_ authority: SocialAuthority) -> Bool {
        authority == .matrix
    }
}
