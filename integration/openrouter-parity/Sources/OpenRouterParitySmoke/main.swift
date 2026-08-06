// Live behavioral smoke: ServerFoundationModels driven through the
// OpenRouterForFoundationModels bridge (built with its ServerFoundationModels
// trait) against a real OpenRouter model. Asserts the library contracts the
// in-repo parity suite can only exercise against the on-device model:
// plain respond, cumulative streaming, guided generation, and the tool loop.
//
//   OPENROUTER_API_KEY=<key> swift run --package-path integration/openrouter-parity
//   OPENROUTER_PARITY_MODEL=<id>  overrides the default model.

import Foundation
import OpenRouterForFoundationModels
import ServerFoundationModels

@Generable
struct CityFact {
    @Guide(description: "The city's name")
    var city: String
    @Guide(description: "Its country")
    var country: String
}

struct Clock: Tool {
    let name = "current_year"
    let description = "Returns the current year as a number."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String { "2026" }
}

@main
struct Smoke {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            print("SKIP: set OPENROUTER_API_KEY to run the live smoke")
            exit(2)
        }
        let modelName = ProcessInfo.processInfo.environment["OPENROUTER_PARITY_MODEL"]
            ?? "anthropic/claude-sonnet-4.5"
        let model = OpenRouterLanguageModel(name: OpenRouterModel(id: modelName), auth: .apiKey(key))
        print("model under test: \(modelName)")
        var failures = 0

        func check(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        await check("respond(to:) returns content and transcript entries") {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: "Reply with one short sentence: what is the capital of France?",
                options: GenerationOptions(temperature: 0)
            )
            guard response.content.localizedCaseInsensitiveContains("Paris") else {
                throw SmokeFailure("expected Paris, got: \(response.content)")
            }
            guard session.transcript.contains(where: { if case .response = $0 { return true }; return false }) else {
                throw SmokeFailure("transcript has no response entry")
            }
        }

        await check("streamResponse(to:) yields cumulative snapshots") {
            let session = LanguageModelSession(model: model)
            var snapshots: [String] = []
            for try await snapshot in session.streamResponse(
                to: "Count from one to five in English words.",
                options: GenerationOptions(temperature: 0)
            ) {
                snapshots.append(snapshot.content)
            }
            guard let final = snapshots.last, !final.isEmpty else {
                throw SmokeFailure("no snapshots")
            }
            guard zip(snapshots, snapshots.dropFirst()).allSatisfy({ $0.count <= $1.count }) else {
                throw SmokeFailure("snapshots not cumulative")
            }
        }

        await check("respond(generating:) decodes a @Generable value") {
            let session = LanguageModelSession(model: model)
            let response = try await session.respond(
                to: "Name the largest city in Japan.",
                generating: CityFact.self,
                options: GenerationOptions(temperature: 0)
            )
            guard !response.content.city.isEmpty, !response.content.country.isEmpty else {
                throw SmokeFailure("empty structured fields: \(response.content)")
            }
        }

        await check("tool calls execute and land in the transcript") {
            let session = LanguageModelSession(model: model, tools: [Clock()]) {
                "Use the current_year tool when asked about the year."
            }
            let response = try await session.respond(
                to: "What year is it? Use the tool, then answer with just the number.",
                options: GenerationOptions(temperature: 0)
            )
            guard session.transcript.contains(where: { if case .toolCalls = $0 { return true }; return false }) else {
                throw SmokeFailure("no toolCalls entry; content: \(response.content)")
            }
            guard response.content.contains("2026") else {
                throw SmokeFailure("tool result not reflected: \(response.content)")
            }
        }

        print(failures == 0 ? "SMOKE GREEN (4/4)" : "SMOKE RED (\(4 - failures)/4)")
        exit(failures == 0 ? 0 : 1)
    }
}

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
