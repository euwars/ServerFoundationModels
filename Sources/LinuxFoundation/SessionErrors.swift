// Session-level error taxonomy. Mirrors FoundationModels (SDK 27):
// LanguageModelSession.GenerationError / ToolCallError / Error,
// GeneratedContent.ParsingError, GenerationSchema.SchemaError,
// TranscriptErrorHandlingPolicy.

import Foundation

extension LanguageModelSession {

    public enum GenerationError: LocalizedError {
        public struct Context: Sendable {
            public let debugDescription: String
            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        public struct Refusal: Sendable {
            let transcriptEntries: [Transcript.Entry]

            public init(transcriptEntries: [Transcript.Entry]) {
                self.transcriptEntries = transcriptEntries
            }

            /// A model-generated explanation of the refusal, produced by
            /// continuing the refusing conversation.
            public var explanation: Response<String> {
                get async throws {
                    let session = LanguageModelSession(
                        model: SystemLanguageModel.default,
                        transcript: Transcript(entries: transcriptEntries)
                    )
                    return try await session.respond(
                        to: "Briefly explain why the previous request was declined."
                    )
                }
            }

            public var explanationStream: ResponseStream<String> {
                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    transcript: Transcript(entries: transcriptEntries)
                )
                return session.streamResponse(
                    to: "Briefly explain why the previous request was declined."
                )
            }
        }

        case exceededContextWindowSize(Context)
        case assetsUnavailable(Context)
        case guardrailViolation(Context)
        case unsupportedGuide(Context)
        case unsupportedLanguageOrLocale(Context)
        case decodingFailure(Context)
        case rateLimited(Context)
        case concurrentRequests(Context)
        case refusal(Refusal, Context)

        public var errorDescription: String? {
            switch self {
            case .exceededContextWindowSize(let context),
                .assetsUnavailable(let context),
                .guardrailViolation(let context),
                .unsupportedGuide(let context),
                .unsupportedLanguageOrLocale(let context),
                .decodingFailure(let context),
                .rateLimited(let context),
                .concurrentRequests(let context),
                .refusal(_, let context):
                return context.debugDescription
            }
        }

        public var failureReason: String? { errorDescription }

        public var recoverySuggestion: String? {
            switch self {
            case .exceededContextWindowSize:
                return "Start a new session or trim the transcript."
            case .concurrentRequests:
                return "Await the in-flight response before sending another request."
            default:
                return nil
            }
        }
    }

    public struct ToolCallError: LocalizedError {
        public var tool: any Tool
        public var underlyingError: any Swift.Error

        public init(tool: any Tool, underlyingError: any Swift.Error) {
            self.tool = tool
            self.underlyingError = underlyingError
        }

        public var errorDescription: String? {
            "Tool '\(tool.name)' failed: \(underlyingError.localizedDescription)"
        }
    }

    /// Service-level failures surfaced by server-backed models.
    public enum Error: LocalizedError, CustomDebugStringConvertible {
        case networkFailure(PrivateCloudComputeLanguageModel.Error.NetworkFailure)
        case quotaLimitReached(PrivateCloudComputeLanguageModel.Error.QuotaLimitReached)
        case serviceUnavailable(PrivateCloudComputeLanguageModel.Error.ServiceUnavailable)

        public var debugDescription: String {
            switch self {
            case .networkFailure(let payload): return payload.debugDescription
            case .quotaLimitReached(let payload): return payload.debugDescription
            case .serviceUnavailable(let payload): return payload.debugDescription
            }
        }

        public var errorDescription: String? { debugDescription }
    }

    /// What happens to the transcript when a request fails.
    public var transcriptErrorHandlingPolicy: TranscriptErrorHandlingPolicy? {
        get { errorPolicy }
        set { errorPolicy = newValue }
    }
}

public struct TranscriptErrorHandlingPolicy: Sendable, Equatable {
    let kind: Kind
    enum Kind: Sendable, Equatable {
        case revert
        case preserve
    }

    public static let revertTranscript = TranscriptErrorHandlingPolicy(kind: .revert)
    public static let preserveTranscript = TranscriptErrorHandlingPolicy(kind: .preserve)
}

// MARK: - GeneratedContent.ParsingError

extension GeneratedContent {
    public struct ParsingError: LocalizedError, CustomDebugStringConvertible {
        public var rawContent: String
        public var underlyingError: (any Swift.Error)?
        public var debugDescription: String

        public init(rawContent: String, underlyingError: (any Swift.Error)? = nil, debugDescription: String) {
            self.rawContent = rawContent
            self.underlyingError = underlyingError
            self.debugDescription = debugDescription
        }

        public var errorDescription: String? { debugDescription }
    }
}

// MARK: - GenerationSchema.SchemaError

extension GenerationSchema {
    public enum SchemaError: LocalizedError {
        public struct Context: Sendable {
            public let debugDescription: String
            public init(debugDescription: String) {
                self.debugDescription = debugDescription
            }
        }

        case duplicateType(schema: String?, type: String, context: Context)
        case duplicateProperty(schema: String, property: String, context: Context)
        case emptyTypeChoices(schema: String, context: Context)
        case undefinedReferences(schema: String?, references: [String], context: Context)

        public var errorDescription: String? {
            switch self {
            case .duplicateType(_, _, let context),
                .duplicateProperty(_, _, let context),
                .emptyTypeChoices(_, let context),
                .undefinedReferences(_, _, let context):
                return context.debugDescription
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .undefinedReferences:
                return "Pass the referenced schemas in 'dependencies'."
            case .duplicateType:
                return "Give each schema type a unique name."
            default:
                return nil
            }
        }
    }
}
