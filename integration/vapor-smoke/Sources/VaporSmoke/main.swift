// Smoke test: ServerFoundationModels inside a Vapor request handler.
import Vapor
import ServerFoundationModels

func makeSession() -> LanguageModelSession {
    if let apiKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] {
        let modelName = ProcessInfo.processInfo.environment["XAI_MODEL"] ?? "grok-4.3-latest"
        let xaiModel: XAIModel
        switch modelName {
        case XAIModel.grok4_20MultiAgent.id: xaiModel = .grok4_20MultiAgent
        case XAIModel.grok4_1Fast.id: xaiModel = .grok4_1Fast
        case XAIModel.grok4_3.id: xaiModel = .grok4_3
        default: xaiModel = .custom(modelName)
        }
        let model = XAILanguageModel(
            name: xaiModel,
            auth: .apiKey(apiKey),
            conversationState: XAIConversationState()
        )
        return LanguageModelSession(model: model)
    }

    let model = ChatCompletionsLanguageModel(
        name: ProcessInfo.processInfo.environment["LF_MODEL"] ?? "qwen3.6-35b-a3b",
        url: URL(string: ProcessInfo.processInfo.environment["LF_BASE_URL"] ?? "http://10.0.0.200:8000")!
    )
    return LanguageModelSession(model: model)
}

let app = try await Application.make(.detect())
app.http.server.configuration.port = 8080

app.get("healthz") { _ in "ok" }

app.get("ask") { req async throws -> String in
    let question = (try? req.query.get(String.self, at: "q")) ?? "Reply with one word: ready"
    let session = makeSession()
    return try await session.respond(to: question).content
}

try await app.execute()
try await app.asyncShutdown()