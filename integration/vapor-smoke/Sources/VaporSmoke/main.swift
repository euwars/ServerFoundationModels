// Smoke test: ServerFoundationModels inside a Vapor request handler.
import Vapor
import ServerFoundationModels

func smokeModel() -> ChatCompletionsLanguageModel {
    ChatCompletionsLanguageModel(
        name: ProcessInfo.processInfo.environment["LF_MODEL"] ?? "qwen3.6-35b-a3b",
        url: URL(string: ProcessInfo.processInfo.environment["LF_BASE_URL"] ?? "http://10.0.0.200:8000")!
    )
}

let app = try await Application.make(.detect())
app.http.server.configuration.port = 8080

app.get("healthz") { _ in "ok" }

app.get("ask") { req async throws -> String in
    let question = (try? req.query.get(String.self, at: "q")) ?? "Reply with one word: ready"
    let session = LanguageModelSession(model: smokeModel())
    return try await session.respond(to: question).content
}

try await app.execute()
try await app.asyncShutdown()
