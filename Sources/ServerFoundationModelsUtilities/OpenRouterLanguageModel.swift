// OpenRouterLanguageModel — a first-class OpenRouter provider.
//
// OpenRouter speaks the OpenAI /chat/completions wire, so this provider owns
// the OpenRouter-*specific* surface — typed provider routing, native web
// search/fetch server tools, reasoning controls, app attribution headers, and
// credit-exhaustion error mapping — and drives the proven OpenAI-compatible
// transport/parsing underneath (streaming, tool calls, usage, and
// `url_citation` → WebCitationSegment all come for free). The OpenRouter
// behaviours captured here are the ones a real research pipeline learned to
// depend on: `engine: "native"` (auto silently falls back to Exa), provider
// routing pinned so a run doesn't drift across backends, and 402 / 403-"credit"
// treated as a terminal stop rather than a retry.

import Foundation
import Logging
import ServerFoundationModels

public struct OpenRouterLanguageModel: Sendable, LanguageModel {
    /// The model slug, e.g. `"anthropic/claude-sonnet-4"` or `"google/gemini-2.5-pro"`.
    public var model: String
    /// Bearer token for `openrouter.ai`. Prefer fetching this at runtime and
    /// storing it in the Keychain over embedding it in the binary.
    public var apiKey: String?
    /// Endpoint base. Defaults to OpenRouter; override to point at a compatible
    /// gateway. `chat/completions` is appended automatically.
    public var baseURL: URL
    /// Pins which upstream providers serve the request, in what order, and
    /// whether fallbacks are allowed — so a run doesn't silently drift.
    public var providerRouting: ProviderRouting?
    /// Provider-executed tools (web search / fetch) injected into the request.
    public var serverTools: [OpenRouterServerTool]
    /// How structured output rides the wire (see `ChatCompletionsLanguageModel.SchemaWire`).
    public var schemaWire: ChatCompletionsLanguageModel.SchemaWire
    /// Reasoning controls for models that support them.
    public var reasoning: Reasoning?
    /// Whether the selected model supports `response_format` structured output.
    public var supportsGuidedGeneration: Bool
    /// Sent as `HTTP-Referer`, for OpenRouter app attribution/leaderboards.
    public var appURL: String?
    /// Sent as `X-Title`, for OpenRouter app attribution/leaderboards.
    public var appTitle: String?
    /// When false, requests are sent non-streaming.
    public var stream: Bool
    /// Per-request timeout, in seconds.
    public var timeout: TimeInterval
    /// Extra headers merged on top of auth/attribution.
    public var additionalHeaders: [String: String]
    /// A JSON object merged verbatim into every request body, for fields not
    /// covered above. Merged after `provider`/`reasoning`.
    public var extraBodyJSON: String?
    /// Transport diagnostics via swift-log. Never logs prompt/response content.
    public var logger = Logger(label: "ServerFoundationModels.OpenRouter", factory: { _ in SwiftLogNoOpLogHandler() })

    public init(
        model: String,
        apiKey: String? = nil,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        providerRouting: ProviderRouting? = nil,
        serverTools: [OpenRouterServerTool] = [],
        schemaWire: ChatCompletionsLanguageModel.SchemaWire = .jsonSchema,
        reasoning: Reasoning? = nil,
        supportsGuidedGeneration: Bool = true,
        appURL: String? = nil,
        appTitle: String? = nil,
        stream: Bool = true,
        timeout: TimeInterval = 600,
        additionalHeaders: [String: String] = [:],
        extraBodyJSON: String? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.providerRouting = providerRouting
        self.serverTools = serverTools
        self.schemaWire = schemaWire
        self.reasoning = reasoning
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.appURL = appURL
        self.appTitle = appTitle
        self.stream = stream
        self.timeout = timeout
        self.additionalHeaders = additionalHeaders
        self.extraBodyJSON = extraBodyJSON
    }

    public var capabilities: LanguageModelCapabilities { asChatCompletions().capabilities }

    public var executorConfiguration: Executor.Configuration { asChatCompletions().executorConfiguration }

    /// Lowers the typed OpenRouter configuration onto the OpenAI-compatible
    /// engine: auth + attribution headers, `provider`/`reasoning`/extra merged
    /// into the request body, and typed server tools rendered to wire form.
    func asChatCompletions() -> ChatCompletionsLanguageModel {
        var headers = additionalHeaders
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        if let appURL { headers["HTTP-Referer"] = appURL }
        if let appTitle { headers["X-Title"] = appTitle }
        var model = ChatCompletionsLanguageModel(
            name: self.model,
            url: baseURL,
            additionalHeaders: headers,
            supportsGuidedGeneration: supportsGuidedGeneration,
            schemaWire: schemaWire,
            serverTools: serverTools.map(\.underlying),
            stream: stream,
            timeout: timeout,
            additionalBodyJSON: mergedBodyJSON()
        )
        model.logger = logger
        return model
    }

    /// Merges typed `provider` routing, `reasoning`, and any `extraBodyJSON`
    /// into one JSON object for the request body. Returns nil when empty.
    func mergedBodyJSON() -> String? {
        var members: [JSONNode.Member] = []
        if let node = providerRouting?.node { members.append(.init(key: "provider", value: node)) }
        if let node = reasoning?.node { members.append(.init(key: "reasoning", value: node)) }
        // Append user extra last so its keys win the de-dupe below.
        if let extraBodyJSON, let parsed = try? JSONNode.parse(extraBodyJSON),
           case .object(let extra) = parsed {
            members.append(contentsOf: extra)
        }
        guard !members.isEmpty else { return nil }
        // De-dupe by key keeping the LAST occurrence (user extra overrides typed).
        var seen = Set<String>()
        let deduped = members.reversed().filter { seen.insert($0.key).inserted }.reversed()
        return JSONNode.object(Array(deduped)).serialized
    }

    // MARK: Executor

    public struct Executor: LanguageModelExecutor {
        public typealias Configuration = ChatCompletionsLanguageModel.Executor.Configuration

        let configuration: Configuration

        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: OpenRouterLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let engine = try ChatCompletionsLanguageModel.Executor(configuration: configuration)
            do {
                try await engine.respond(to: request, model: model.asChatCompletions(), streamingInto: channel)
            } catch let error as LanguageModelTransportError
                where HTTPErrorHeuristics.isCreditExhaustion(statusCode: error.statusCode, body: error.message) {
                throw OpenRouterError.creditExhausted(statusCode: error.statusCode, message: error.message)
            }
        }
    }
}

// MARK: - Provider routing

extension OpenRouterLanguageModel {
    /// Typed subset of OpenRouter's `provider` routing object.
    public struct ProviderRouting: Sendable, Hashable {
        public enum Sort: String, Sendable, Hashable { case price, throughput, latency }
        public enum DataCollection: String, Sendable, Hashable { case allow, deny }

        /// Preferred providers, in order.
        public var order: [String]?
        /// Restrict to exactly these providers.
        public var only: [String]?
        /// Never use these providers.
        public var ignore: [String]?
        /// Allow falling back to other providers when the preferred ones fail.
        public var allowFallbacks: Bool?
        /// Only route to providers that support every request parameter.
        public var requireParameters: Bool?
        /// Sort candidate providers by this axis.
        public var sort: Sort?
        /// Whether upstreams may retain data.
        public var dataCollection: DataCollection?

        public init(
            order: [String]? = nil, only: [String]? = nil, ignore: [String]? = nil,
            allowFallbacks: Bool? = nil, requireParameters: Bool? = nil,
            sort: Sort? = nil, dataCollection: DataCollection? = nil
        ) {
            self.order = order; self.only = only; self.ignore = ignore
            self.allowFallbacks = allowFallbacks; self.requireParameters = requireParameters
            self.sort = sort; self.dataCollection = dataCollection
        }

        var node: JSONNode? {
            var members: [JSONNode.Member] = []
            if let order { members.append(.init(key: "order", value: .array(order.map(JSONNode.string)))) }
            if let only { members.append(.init(key: "only", value: .array(only.map(JSONNode.string)))) }
            if let ignore { members.append(.init(key: "ignore", value: .array(ignore.map(JSONNode.string)))) }
            if let allowFallbacks { members.append(.init(key: "allow_fallbacks", value: .bool(allowFallbacks))) }
            if let requireParameters { members.append(.init(key: "require_parameters", value: .bool(requireParameters))) }
            if let sort { members.append(.init(key: "sort", value: .string(sort.rawValue))) }
            if let dataCollection { members.append(.init(key: "data_collection", value: .string(dataCollection.rawValue))) }
            return members.isEmpty ? nil : .object(members)
        }
    }

    /// Typed subset of OpenRouter's `reasoning` object.
    public struct Reasoning: Sendable, Hashable {
        public enum Effort: String, Sendable, Hashable { case low, medium, high }

        public var effort: Effort?
        public var maxTokens: Int?
        public var enabled: Bool?
        /// Drop reasoning tokens from the response (still used internally).
        public var exclude: Bool?

        public init(effort: Effort? = nil, maxTokens: Int? = nil, enabled: Bool? = nil, exclude: Bool? = nil) {
            self.effort = effort; self.maxTokens = maxTokens; self.enabled = enabled; self.exclude = exclude
        }

        var node: JSONNode? {
            var members: [JSONNode.Member] = []
            if let effort { members.append(.init(key: "effort", value: .string(effort.rawValue))) }
            if let maxTokens { members.append(.init(key: "max_tokens", value: .integer(maxTokens))) }
            if let enabled { members.append(.init(key: "enabled", value: .bool(enabled))) }
            if let exclude { members.append(.init(key: "exclude", value: .bool(exclude))) }
            return members.isEmpty ? nil : .object(members)
        }
    }
}

// MARK: - Server tools

extension OpenRouterLanguageModel {
    /// A provider-executed OpenRouter tool (web search / fetch). Runs
    /// server-side; grounded answers and `url_citation` annotations return in
    /// the same streamed response.
    public struct OpenRouterServerTool: Sendable, Hashable {
        let underlying: ChatCompletionsServerTool

        public enum WebSearchEngine: String, Sendable, Hashable {
            /// The upstream provider's own grounding (Google for Gemini, etc.).
            case native
            /// Exa-backed search.
            case exa
            /// Native when available, else Exa — can fall back silently.
            case auto
        }

        /// OpenRouter web search. Pass `.native` explicitly when you need the
        /// provider's own grounding — `.auto` may silently fall back to Exa.
        public static func webSearch(
            engine: WebSearchEngine = .auto,
            maxResults: Int? = nil,
            maxTotalResults: Int? = nil
        ) -> OpenRouterServerTool {
            OpenRouterServerTool(underlying: .openRouterWebSearch(
                engine: engine.rawValue, maxResults: maxResults, maxTotalResults: maxTotalResults
            ))
        }

        /// OpenRouter web fetch — lets the model pull a specific URL's contents.
        public static func webFetch() -> OpenRouterServerTool {
            OpenRouterServerTool(underlying: .openRouterWebFetch())
        }
    }
}

// MARK: - Errors

/// Failures specific to OpenRouter that no generic `LanguageModelError` case
/// captures. Transport, rate-limit, and context-overflow errors still surface
/// as the shared `LanguageModelError`/`LanguageModelTransportError` types.
public enum OpenRouterError: Error, LocalizedError, CustomStringConvertible {
    /// The account is out of credit or over its key limit (HTTP 402, or 403
    /// whose body mentions "key limit"/"credit"). Terminal: every later request
    /// fails identically, so stop the run and top up rather than retrying.
    case creditExhausted(statusCode: Int, message: String)

    public var description: String {
        switch self {
        case .creditExhausted(let status, let message):
            return "OpenRouter credit exhausted (HTTP \(status)): \(message.prefix(200))"
        }
    }

    public var errorDescription: String? { description }
}
