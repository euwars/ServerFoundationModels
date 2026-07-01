// xAI model identifiers and per-model behavior flags.

import Foundation

public struct XAIModel: Sendable, Hashable {
    public let id: String
    public let supportsThreading: Bool
    public let supportsGuidedGeneration: Bool
    public let supportsVision: Bool
    public let defaultReasoningEffort: XAIReasoningEffort

    public init(
        id: String,
        supportsThreading: Bool = true,
        supportsGuidedGeneration: Bool = true,
        supportsVision: Bool = true,
        defaultReasoningEffort: XAIReasoningEffort = .high
    ) {
        self.id = id
        self.supportsThreading = supportsThreading
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.supportsVision = supportsVision
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    public static let grok4_3 = XAIModel(id: "grok-4.3-latest")
    public static let grok4_20MultiAgent = XAIModel(
        id: "grok-4.20-multi-agent",
        supportsThreading: false,
        defaultReasoningEffort: .medium
    )
    public static let grok4_1Fast = XAIModel(id: "grok-4-1-fast-reasoning-latest")

    public static func custom(
        _ id: String,
        supportsThreading: Bool = true,
        supportsGuidedGeneration: Bool = true,
        supportsVision: Bool = true,
        defaultReasoningEffort: XAIReasoningEffort = .high
    ) -> XAIModel {
        XAIModel(
            id: id,
            supportsThreading: supportsThreading && !id.contains("multi-agent"),
            supportsGuidedGeneration: supportsGuidedGeneration,
            supportsVision: supportsVision,
            defaultReasoningEffort: defaultReasoningEffort
        )
    }
}

public enum XAIReasoningEffort: String, Sendable, Hashable, Codable {
    case low
    case medium
    case high
}