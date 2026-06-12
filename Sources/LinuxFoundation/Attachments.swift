// Prompt attachments and image references (SDK 27), plus the
// PrivateCloudComputeLanguageModel surface.
//
// Attachment delivery to executors lands with multimodal request support;
// these types provide source parity today so code using them compiles
// unchanged.

import Foundation

public struct GenerationID: Sendable, Hashable {
    let raw: UUID
    public init() { self.raw = UUID() }
}

public protocol AttachmentContent {}

public struct Attachment<Content: AttachmentContent> {
    public var label: String?
    public var content: Content

    public init(label: String? = nil, content: Content) {
        self.label = label
        self.content = content
    }
}

public struct ImageAttachmentContent: AttachmentContent, Sendable, Equatable {
    public var data: Data
    public var mimeType: String?

    public init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// A model-generated reference to an attached image, identified by label.
public struct ImageReference: Sendable, Equatable, Generable {
    public let attachmentLabel: String

    init(attachmentLabel: String) {
        self.attachmentLabel = attachmentLabel
    }

    public init(_ content: GeneratedContent) throws {
        self.attachmentLabel = try content.value(String?.self, forProperty: "attachmentLabel") ?? ""
    }

    /// The attached image this reference points to, if present in the
    /// transcript's attachment segments.
    public func resolve(in transcript: Transcript) -> Transcript.ImageAttachment? {
        for entry in transcript {
            let segments: [Transcript.Segment]
            switch entry {
            case .prompt(let prompt): segments = prompt.segments
            case .response(let response): segments = response.segments
            case .instructions(let instructions): segments = instructions.segments
            default: continue
            }
            for segment in segments {
                if case .attachment(let attachment) = segment,
                    attachment.label == attachmentLabel,
                    case .image(let image) = attachment.content {
                    return image
                }
            }
        }
        return nil
    }

    public struct PartiallyGenerated: Identifiable, ConvertibleFromGeneratedContent, Equatable {
        public var id: GenerationID
        public var attachmentLabel: String?

        public init(_ content: GeneratedContent) throws {
            self.id = content.id ?? GenerationID()
            self.attachmentLabel = try content.value(String?.self, forProperty: "attachmentLabel")
        }
    }

    public static var generationSchema: GenerationSchema {
        GenerationSchema(node: .object(
            name: "ImageReference",
            description: "A reference to an attached image",
            properties: [
                .init(
                    name: "attachmentLabel",
                    description: "Label of the referenced attachment",
                    node: .string(description: nil, enumChoices: nil, pattern: nil),
                    isOptional: true
                )
            ]
        ))
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["attachmentLabel": attachmentLabel])
    }
}

// MARK: - Private Cloud Compute

/// Apple's server model. Requires the managed Private Cloud Compute
/// entitlement on Apple platforms; never available on Linux. Provided for
/// source parity so profile code selecting between models compiles unchanged.
public final class PrivateCloudComputeLanguageModel: Sendable, LanguageModel {
    public init() {}

    @frozen public enum Availability: Equatable, Sendable {
        case available
        case unavailable(UnavailableReason)

        public enum UnavailableReason: Equatable, Sendable {
            case deviceNotEligible
            case systemNotReady
        }
    }

    public var availability: Availability {
        .unavailable(.deviceNotEligible)
    }

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling, .guidedGeneration, .reasoning, .vision])
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration()
    }

    public enum Error: LocalizedError, CustomDebugStringConvertible {
        public struct NetworkFailure: Sendable {
            public var debugDescription: String
            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        public struct QuotaLimitReached: Sendable {
            public var debugDescription: String
            public var limitIncreaseSuggestion: QuotaUsage.LimitIncreaseSuggestion?
            public var resetDate: Date?
            public init(
                debugDescription: String,
                limitIncreaseSuggestion: QuotaUsage.LimitIncreaseSuggestion? = nil,
                resetDate: Date? = nil
            ) {
                self.debugDescription = debugDescription
                self.limitIncreaseSuggestion = limitIncreaseSuggestion
                self.resetDate = resetDate
            }
        }

        public struct ServiceUnavailable: Sendable {
            public var debugDescription: String
            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        case networkFailure(NetworkFailure)
        case quotaLimitReached(QuotaLimitReached)
        case serviceUnavailable(ServiceUnavailable)

        public var debugDescription: String {
            switch self {
            case .networkFailure(let payload): return payload.debugDescription
            case .quotaLimitReached(let payload): return payload.debugDescription
            case .serviceUnavailable(let payload): return payload.debugDescription
            }
        }

        public var errorDescription: String? { debugDescription }
    }

    public struct QuotaUsage: Sendable {
        public var status: Status
        public var limitIncreaseSuggestion: LimitIncreaseSuggestion?
        public var resetDate: Date?

        public var isLimitReached: Bool {
            if case .limitReached = status { return true }
            return false
        }

        public enum Status: Sendable {
            case belowLimit(BelowLimit)
            case limitReached(LimitReached)

            public struct BelowLimit: Sendable {
                public var isApproachingLimit: Bool
            }

            public struct LimitReached: Sendable {}
        }

        public struct LimitIncreaseSuggestion: Sendable {
            public func show() {}
        }
    }

    /// Quota state for Private Cloud Compute. Without the entitlement (and on
    /// Linux) the model is unavailable, reported as a reached limit.
    public var quotaUsage: QuotaUsage {
        QuotaUsage(status: .limitReached(.init()), limitIncreaseSuggestion: nil, resetDate: nil)
    }

    public var isAvailable: Bool {
        availability == .available
    }

    public var contextSize: Int { 0 }

    public var supportedLanguages: Set<Locale.Language> { [] }

    public func supportsLocale(_ locale: Locale = Locale.current) -> Bool { false }

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            public init() {}
        }

        public init(configuration: Configuration) throws {}

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PrivateCloudComputeLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            throw LanguageModelTransportError(
                statusCode: 0,
                message: "PrivateCloudComputeLanguageModel requires the Private Cloud Compute entitlement on an Apple platform"
            )
        }
    }
}
