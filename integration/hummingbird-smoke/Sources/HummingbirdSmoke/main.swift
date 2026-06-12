// Smoke test: LinuxFoundation inside a Hummingbird request handler.
import Hummingbird
import LinuxFoundation
import Foundation

func smokeModel() -> ChatCompletionsLanguageModel {
    ChatCompletionsLanguageModel(
        name: ProcessInfo.processInfo.environment["LF_MODEL"] ?? "qwen3.6-35b-a3b",
        url: URL(string: ProcessInfo.processInfo.environment["LF_BASE_URL"] ?? "http://10.0.0.200:8000")!
    )
}

let router = Router()
router.get("healthz") { _, _ in "ok" }
router.get("ask") { request, _ -> String in
    let question = request.uri.queryParameters.get("q") ?? "Reply with one word: ready"
    let session = LanguageModelSession(model: smokeModel())
    return try await session.respond(to: question).content
}

let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: 8081))
)
try await app.runService()
