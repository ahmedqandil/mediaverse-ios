import Foundation

@MainActor
final class RippleEngagementController: ObservableObject {
    @Published private(set) var energyCount: Int
    @Published private(set) var energyTotal: Int
    @Published private(set) var energyTags: [String]
    @Published private(set) var shareCount: Int
    @Published private(set) var poll: RipplePoll?
    @Published private(set) var currentEnergy: RippleEnergySelection?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let rippleId: String
    private let api: LegacySocialAPIAdapter

    init(
        ripple: Ripple,
        api: LegacySocialAPIAdapter = LegacySocialAPIAdapter(transport: APIClient.shared)
    ) {
        rippleId = ripple.id
        energyCount = ripple.energyCount
        energyTotal = ripple.energyTotal
        energyTags = ripple.energyTags
        shareCount = ripple.shareCount
        poll = ripple.poll
        self.api = api
    }

    func loadEnergy() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            apply(try await api.rippleEnergy(postId: rippleId))
        } catch {
            errorMessage = message(for: error)
        }
    }

    func submitEnergy(overall: Int, tags: [String]) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await api.addEnergy(toRipple: rippleId, overall: overall, tags: tags)
            apply(try await api.rippleEnergy(postId: rippleId))
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func vote(optionIds: [String]) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            poll = try await api.vote(
                inPoll: poll?.id ?? "",
                optionIds: optionIds
            ).poll
        } catch {
            errorMessage = message(for: error)
        }
    }

    func recordNativeShare() async {
        do {
            shareCount = try await api.recordShare(
                ofRipple: rippleId,
                channel: .native
            ).shareCount
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func apply(_ response: RippleEnergyResponse) {
        currentEnergy = response.userRating
        energyCount = response.aggregate.count
        energyTotal = Int(((response.aggregate.avg ?? 0) * Double(response.aggregate.count)).rounded())
        energyTags = response.aggregate.topTags
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "The Ripple could not be updated."
    }
}
