// xAI Grok as a Foundation Models server-side language model via the
// Responses API (/v1/responses).

import Foundation
import Logging
import Synchronization
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
        public struct Configuration: Hashable, Sendable, CustomStringConvertible {
            var model: XAIModel
            var auth: XAIAuthMode
            var serverTools: Set<XAIServerTool>
            var baseURL: URL
            var timeout: TimeInterval

            public var description: String {
                "Configuration(model: \(model), auth: \(auth), serverTools: \(serverTools), baseURL: \(baseURL), timeout: \(timeout))"
            }
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
                let parsed = try await streamAndParse(
                    built.request,
                    auth: configuration.auth,
                    baseURL: configuration.baseURL,
                    timeout: configuration.timeout,
                    channel: channel,
                    logger: logger
                )
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

        private func streamAndParse(
            _ body: XAIResponsesRequest,
            auth: XAIAuthMode,
            baseURL: URL,
            timeout: TimeInterval,
            channel: LanguageModelExecutorGenerationChannel,
            logger: Logger
        ) async throws -> XAIResponseTranslator.Parsed {
            var urlRequest = URLRequest(url: baseURL)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            applyAuth(auth, to: &urlRequest)
            var streamingBody = body
            streamingBody.stream = true
            urlRequest.httpBody = try streamingBody.bodyJSON()
            try validateAuth(auth)
            warnIfInsecureHTTP(baseURL: baseURL, auth: auth, logger: logger)

            let (lines, response) = try await HTTPLineStream.connect(urlRequest)
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""

            if response.statusCode >= 400 || contentType.contains("application/json") {
                var bodyLines: [String] = []
                var bodySize = 0
                for try await line in lines {
                    bodyLines.append(line)
                    if response.statusCode >= 400 {
                        bodySize += line.utf8.count
                        if bodySize > 4096 { break }
                    }
                }
                let responseBody = bodyLines.joined(separator: "\n")
                if response.statusCode >= 400 {
                    logger.warning("xai.responses error", metadata: [
                        "status": .stringConvertible(response.statusCode),
                        "body": .string(String(responseBody.prefix(256))),
                    ])
                    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                    throw XAIError(status: response.statusCode, body: responseBody, retryAfter: retryAfter)
                }
                // Server honored the request but replied with a single non-streamed
                // JSON document; parse the whole body rather than truncating it.
                guard !responseBody.isEmpty else {
                    throw XAIError(status: response.statusCode, body: responseBody)
                }
                let parsed = try XAIResponseTranslator.parse(body: Data(responseBody.utf8))
                await XAIResponseTranslator.emit(parsed, into: channel)
                return parsed
            }

            var accumulator = XAIResponseStream.Accumulator()
            var pendingData: [String] = []
            var isFirstLine = true

            for try await rawLine in lines {
                var line = Substring(rawLine)
                if isFirstLine {
                    isFirstLine = false
                    if line.first == "\u{FEFF}" { line.removeFirst() }
                }
                if line.isEmpty {
                    guard !pendingData.isEmpty else { continue }
                    let payload = pendingData.joined(separator: "\n")
                    pendingData.removeAll()
                    let actions = try accumulator.ingest(payload: payload)
                    for action in actions {
                        await XAIResponseStream.emit(action, into: channel)
                    }
                    if accumulator.isTerminal { break }
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                var value = line.dropFirst(5)
                if value.first == " " { value.removeFirst() }
                pendingData.append(String(value))
            }

            if !pendingData.isEmpty {
                let actions = try accumulator.ingest(payload: pendingData.joined(separator: "\n"))
                for action in actions {
                    await XAIResponseStream.emit(action, into: channel)
                }
            }

            return try accumulator.finish()
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

        private func validateAuth(_ auth: XAIAuthMode) throws {
            switch auth {
            case .apiKey(let key):
                if key.contains("\n") || key.contains("\r") {
                    throw TransportConfigurationError("API key must not contain newline characters")
                }
            case .proxied(let headers):
                for (name, value) in headers {
                    if value.contains("\n") || value.contains("\r") {
                        throw TransportConfigurationError(
                            "header \(name) value must not contain newline characters"
                        )
                    }
                }
            }
        }

        private func warnIfInsecureHTTP(baseURL: URL, auth: XAIAuthMode, logger: Logger) {
            guard baseURL.scheme?.lowercased() == "http", authCarriesCredentials(auth) else { return }
            let shouldWarn = XAIHTTPWarnings.didWarnInsecureHTTP.withLock { warned in
                let shouldWarn = !warned
                warned = true
                return shouldWarn
            }
            if shouldWarn {
                logger.warning("xAI base URL uses plain HTTP while auth carries credentials")
            }
        }

        private func authCarriesCredentials(_ auth: XAIAuthMode) -> Bool {
            switch auth {
            case .apiKey: return true
            case .proxied(let headers): return !headers.isEmpty
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

private enum XAIHTTPWarnings {
    static let didWarnInsecureHTTP = Mutex(false)
}
