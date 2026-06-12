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
    public var attachmentLabel: String?

    public init(attachmentLabel: String? = nil) {
        self.attachmentLabel = attachmentLabel
    }

    public init(_ content: GeneratedContent) throws {
        self.attachmentLabel = try content.value(String?.self, forProperty: "attachmentLabel")
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
