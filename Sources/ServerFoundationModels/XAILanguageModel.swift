// xAI Grok as a Foundation Models server-side language model via the
// Responses API (/v1/responses).

import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct XAILanguageModel: Sendable, LanguageModel {
    public var model: XAIModel
    public var auth: XAIAuthMode
    public var conversationState: XAIConversationState
    public var serverTools: Set<XAIServerTool>
    public var baseURL: URL
    public var timeout: TimeInterval

    public var logger = Logger(label: "ServerFoundationModels", factory: { _ in SwiftLogNoOpLogHandler() })

    public init(
        name: XAIModel,
        auth: XAIAuthMode,
        conversationState: XAIConversationState = XAIConversationState(),
        serverTools: Set<XAIServerTool> = [],
        baseURL: URL = XAILanguageModel.defaultBaseURL,
        timeout: TimeInterval = 300
    ) {
        self.model = name
        self.auth = auth
        self.conversationState = conversationState
        self.serverTools = serverTools
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public static let defaultBaseURL = URL(string: "https://api.x.ai/v1/responses")!

    public var capabilities: LanguageModelCapabilities {
        var caps: [LanguageModelCapabilities.Capability] = [.toolCalling, .reasoning]
        if model.supportsVision { caps.append(.vision) }
        if model.supportsGuidedGeneration { caps.append(.guidedGeneration) }
        return LanguageModelCapabilities(capabilities: caps)
    }

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            model: model,
            auth: auth,
            serverTools: serverTools,
            baseURL: baseURL,
            timeout: timeout
        )
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public struct Configuration: Hashable, Sendable {
            var model: XAIModel
            var auth: XAIAuthMode
            var serverTools: Set<XAIServerTool>
            var baseURL: URL
            var timeout: TimeInterval
        }

        let configuration: Configuration

        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: XAILanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let logger = model.logger
            updateStateBeforeRequest(transcript: request.transcript, state: model.conversationState)

            do {
                try await execute(
                    request: request,
                    model: model,
                    channel: channel,
                    allowThreadingFallback: true,
                    logger: logger
                )
            } catch let error as XAIError {
                throw XAIErrorMapper.map(error)
            }
        }

        private func execute(
            request: LanguageModelExecutorGenerationRequest,
            model: XAILanguageModel,
            channel: LanguageModelExecutorGenerationChannel,
            allowThreadingFallback: Bool,
            logger: Logger
        ) async throws {
            let built = try XAIRequestBuilder.build(
                from: request,
                model: configuration.model,
                serverTools: configuration.serverTools,
                conversationState: model.conversationState
            )

            do {
                let parsed = try await postAndParse(
                    built.request,
                    auth: configuration.auth,
                    baseURL: configuration.baseURL,
                    timeout: configuration.timeout,
                    logger: logger
                )
                await XAIResponseTranslator.emit(parsed, into: channel)
                model.conversationState.recordExecutorSuccess(
                    responseId: parsed.responseId,
                    rawOutput: parsed.rawOutput,
                    outputText: parsed.text,
                    userPrompt: built.userPrompt,
                    modelId: configuration.model.id,
                    transcriptEntryCount: request.transcript.count,
                    turnCompleted: parsed.toolCalls.isEmpty
                )
            } catch let error as XAIError where allowThreadingFallback
                && XAIError.isThreadingContentElementError(error)
                && isThreaded(built.mode) {
                logger.warning("xAI threading 400 — falling back to inline replay")
                model.conversationState.clearThreadingForFallback()
                try await execute(
                    request: request,
                    model: model,
                    channel: channel,
                    allowThreadingFallback: false,
                    logger: logger
                )
            }
        }

        private func isThreaded(_ mode: XAIConversationState.ThreadingMode) -> Bool {
            if case .threaded = mode { return true }
            return false
        }

        private func postAndParse(
            _ body: XAIResponsesRequest,
            auth: XAIAuthMode,
            baseURL: URL,
            timeout: TimeInterval,
            logger: Logger
        ) async throws -> XAIResponseTranslator.Parsed {
            var urlRequest = URLRequest(url: baseURL)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            applyAuth(auth, to: &urlRequest)
            urlRequest.httpBody = try body.bodyJSON()

            let response = try await XAIHTTPClient.post(urlRequest, logger: logger)
            let responseBody = String(data: response.data, encoding: .utf8) ?? ""

            guard response.statusCode < 400 else {
                logger.warning("xai.responses error", metadata: [
                    "status": .stringConvertible(response.statusCode),
                    "body": .string(String(responseBody.prefix(256))),
                ])
                throw XAIError(status: response.statusCode, body: responseBody)
            }

            return try XAIResponseTranslator.parse(body: response.data)
        }

        private func applyAuth(_ auth: XAIAuthMode, to request: inout URLRequest) {
            switch auth {
            case .apiKey(let key):
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .proxied(let headers):
                for (header, value) in headers {
                    request.setValue(value, forHTTPHeaderField: header)
                }
            }
        }

        private func updateStateBeforeRequest(
            transcript: Transcript,
            state: XAIConversationState
        ) {
            let count = transcript.count
            let lastSent = state.lastSentIndex()
            guard count > lastSent else { return }

            let entries = Array(transcript.allEntries)
            let delta = entries[lastSent..<count]
            let hasNewPrompt = delta.contains { entry in
                if case .prompt = entry { return true }
                return false
            }

            if hasNewPrompt {
                state.beginUserTurn(transcriptEntryCount: count)
            } else {
                state.beginToolLoopRound(transcriptEntryCount: count)
            }
        }
    }
}