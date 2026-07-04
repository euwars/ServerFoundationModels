// ChatCompletionsServerTool — a provider-executed server tool injected verbatim
// into the `tools` array of a chat-completions request (e.g. OpenRouter's
// `openrouter:web_search` / `openrouter:web_fetch`). Unlike function tools,
// these run entirely server-side; the model's grounded answer and any
// `url_citation` annotations come back in the same streamed response.

import Foundation

public struct ChatCompletionsServerTool: Sendable, Hashable {
    /// The serialized tool object, e.g. `{"type":"openrouter:web_search"}`.
    public let json: String

    public init(rawJSON: String) {
        self.json = rawJSON
    }

    /// OpenRouter web search. `engine` defaults to `auto` (native provider search
    /// when available, else Exa). `maxResults` / `maxTotalResults` bound cost.
    public static func openRouterWebSearch(
        engine: String? = "auto",
        maxResults: Int? = nil,
        maxTotalResults: Int? = nil
    ) -> ChatCompletionsServerTool {
        var params: [String] = []
        if let engine { params.append("\"engine\":\"\(engine)\"") }
        if let maxResults { params.append("\"max_results\":\(maxResults)") }
        if let maxTotalResults { params.append("\"max_total_results\":\(maxTotalResults)") }
        let parameters = params.isEmpty ? "" : ",\"parameters\":{\(params.joined(separator: ","))}"
        return ChatCompletionsServerTool(rawJSON: "{\"type\":\"openrouter:web_search\"\(parameters)}")
    }

    /// OpenRouter web fetch — lets the model pull the contents of a specific URL.
    public static func openRouterWebFetch() -> ChatCompletionsServerTool {
        ChatCompletionsServerTool(rawJSON: "{\"type\":\"openrouter:web_fetch\"}")
    }
}
