import CoreML
import Foundation

enum StoryBeautyModelTier: String, Sendable {
    case live = "MediaverseBeautyLive"
    case render = "MediaverseBeautyRender"
}

enum StoryBeautyModelAvailability: Equatable, Sendable {
    case ready
    case notBundled
    case incompatible(String)
}

/// Fail-closed loader for Mediaverse-owned Beauty models.
///
/// Shipping remains on the deterministic Core Image renderer until an accepted model
/// is bundled. A malformed or partially deployed model can never silently alter media.
final class StoryBeautyModelRuntime: @unchecked Sendable {
    static let shared = StoryBeautyModelRuntime()

    private let lock = NSLock()
    private var models: [StoryBeautyModelTier: MLModel] = [:]
    private var states: [StoryBeautyModelTier: StoryBeautyModelAvailability] = [:]

    private let requiredInputs: Set<String> = ["image", "semantic_masks", "controls"]
    private let requiredOutputs: Set<String> = [
        "residual",
        "confidence",
        "refined_skin_mask",
        "detail",
    ]

    func availability(for tier: StoryBeautyModelTier) -> StoryBeautyModelAvailability {
        lock.withLock {
            if let state = states[tier] {
                return state
            }

            guard let url = Bundle.main.url(forResource: tier.rawValue, withExtension: "mlmodelc") else {
                states[tier] = .notBundled
                return .notBundled
            }

            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = tier == .live ? .cpuAndNeuralEngine : .all
                let model = try MLModel(contentsOf: url, configuration: configuration)
                let creatorMetadata = model.modelDescription.metadata[.creatorDefinedKey]
                    as? [String: String]
                guard creatorMetadata?["mediaverse.usage_scope"] == "commercial" else {
                    let reason = "Beauty model is not licensed for commercial use"
                    states[tier] = .incompatible(reason)
                    return .incompatible(reason)
                }
                let inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
                let outputNames = Set(model.modelDescription.outputDescriptionsByName.keys)
                guard requiredInputs.isSubset(of: inputNames),
                      requiredOutputs.isSubset(of: outputNames) else {
                    let reason = "Unexpected Beauty model interface"
                    states[tier] = .incompatible(reason)
                    return .incompatible(reason)
                }
                models[tier] = model
                states[tier] = .ready
                return .ready
            } catch {
                let reason = error.localizedDescription
                states[tier] = .incompatible(reason)
                return .incompatible(reason)
            }
        }
    }

    func model(for tier: StoryBeautyModelTier) -> MLModel? {
        guard availability(for: tier) == .ready else { return nil }
        return lock.withLock { models[tier] }
    }
}
