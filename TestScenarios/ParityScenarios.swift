// ParityScenarios.swift
//
// This SINGLE source file is compiled into TWO test targets (via symlink):
//
//   Tests/AppleFoundationModelsParityTests  → `import FoundationModels`
//       runs against Apple's local on-device model (SystemLanguageModel.default)
//
//   Tests/OpenFoundationModelsParityTests   → `import OpenFoundationModels`
//       runs against a local open model (ChatCompletionsLanguageModel → Ollama)
//
// Only the import — and which local model answers — differs. Every line of test
// code and every assertion is identical. The models are different, so scenarios
// assert behavioral contracts of the LIBRARY (API semantics, transcript shape,
// schema enforcement, tool-call loop, streaming behavior), never exact strings.
//
// Each target supplies its own `ParityModel` (ModelProvider.swift).

import Foundation
import Testing

#if PARITY_SUBJECT_IS_OPEN_FOUNDATION_MODELS
import OpenFoundationModels
#elseif canImport(FoundationModels)
import FoundationModels
#endif

#if PARITY_SUBJECT_IS_OPEN_FOUNDATION_MODELS || canImport(FoundationModels)

private let deterministic = GenerationOptions(temperature: 0)

// MARK: - Behavior parity (requires a live local model)

@Suite(
    "Behavior parity (local model)",
    .serialized,
    .enabled(if: ParityModel.isAvailable, "local model is not available")
)
struct BehaviorParityScenarios {

    @Test("which model is under test")
    func modelUnderTest() {
        // Not an assertion — records which local model answered for this run.
        print("Parity model under test: \(ParityModel.displayName)")
    }

    @Test("respond(to:) returns non-empty content and records prompt + response in the transcript")
    func plainTextResponse() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Reply with one short sentence: what is the capital of France?",
            options: deterministic
        )

        #expect(!response.content.isEmpty)
        #expect(response.content.localizedCaseInsensitiveContains("Paris"))

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .prompt = $0 { return true }; return false })
        #expect(entries.contains { if case .response = $0 { return true }; return false })
        if case .response = entries.last {} else {
            Issue.record("last transcript entry should be the response, got \(String(describing: entries.last))")
        }
    }

    @Test("instructions are honored and recorded as the first transcript entry")
    func instructionsInTranscript() async throws {
        let session = LanguageModelSession(
            model: ParityModel.make(),
            instructions: "You are a terse assistant. Answer with a single word when possible."
        )
        let response = try await session.respond(
            to: "What color is a ripe banana?",
            options: deterministic
        )

        #expect(!response.content.isEmpty)
        if case .instructions = session.transcript.first {} else {
            Issue.record("first transcript entry should be the instructions, got \(String(describing: session.transcript.first))")
        }
    }

    @Test("streamResponse(to:) yields cumulative snapshots that settle into the final content")
    func streamingSnapshotsAccumulate() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        let stream = session.streamResponse(
            to: "Count from one to five in English words.",
            options: deterministic
        )

        var snapshots: [String] = []
        for try await snapshot in stream {
            snapshots.append(snapshot.content)
        }

        let final = try #require(snapshots.last)
        #expect(!final.isEmpty)
        // Snapshots are cumulative: each one extends the previous.
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.count <= $1.count })
        #expect(session.isResponding == false)

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .response = $0 { return true }; return false })
    }

    @Test("respond(to:schema:) yields complete structured content matching a dynamic schema")
    func structuredOutputWithDynamicSchema() async throws {
        let root = DynamicGenerationSchema(
            name: "CityFact",
            properties: [
                .init(
                    name: "city",
                    description: "Name of the city",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "population",
                    description: "Approximate population as an integer",
                    schema: DynamicGenerationSchema(type: Int.self)
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "Give one fact about Tokyo.",
            schema: schema,
            options: deterministic
        )

        let city: String = try response.content.value(String.self, forProperty: "city")
        let population: Int = try response.content.value(Int.self, forProperty: "population")
        #expect(!city.isEmpty)
        #expect(population > 0)
        #expect(response.content.isComplete)
    }

    @Test("anyOf schema constrains the response to one of the allowed choices")
    func guidedAnyOfChoice() async throws {
        let schema = GenerationSchema(
            type: String.self,
            description: "The color of a clear daytime sky",
            anyOf: ["red", "blue", "green", "yellow"]
        )

        let session = LanguageModelSession(model: ParityModel.make())
        let response = try await session.respond(
            to: "What is the color of a clear daytime sky?",
            schema: schema,
            options: deterministic
        )

        let value: String = try response.content.value(String.self)
        #expect(["red", "blue", "green", "yellow"].contains(value))
    }

    @Test("tool calls are executed and recorded as toolCalls + toolOutput transcript entries")
    func toolCalling() async throws {
        let recorder = CallRecorder()
        let session = LanguageModelSession(
            model: ParityModel.make(),
            tools: [ThermometerTool(recorder: recorder)],
            instructions: "Use the available tools to answer questions about temperature. Always call the tool rather than guessing."
        )
        let response = try await session.respond(
            to: "What is the current temperature in Tokyo? Use the currentTemperature tool.",
            options: deterministic
        )

        #expect(recorder.calls.count >= 1)
        #expect(!response.content.isEmpty)
        #expect(response.content.contains("18"))

        let entries = Array(session.transcript)
        #expect(entries.contains { if case .toolCalls = $0 { return true }; return false })
        #expect(entries.contains { if case .toolOutput = $0 { return true }; return false })
    }

    @Test("a new session resumed from a transcript retains conversation context")
    func transcriptContinuation() async throws {
        let first = LanguageModelSession(model: ParityModel.make())
        _ = try await first.respond(
            to: "My favorite animal is the otter. Acknowledge this in one short sentence.",
            options: deterministic
        )
        let priorCount = first.transcript.count

        let resumed = LanguageModelSession(model: ParityModel.make(), transcript: first.transcript)
        let response = try await resumed.respond(
            to: "What is my favorite animal? Answer with just the animal name.",
            options: deterministic
        )

        #expect(response.content.localizedCaseInsensitiveContains("otter"))
        #expect(resumed.transcript.count > priorCount)
    }

    @Test("prewarm is safe to call and the session still responds")
    func prewarmIsSafe() async throws {
        let session = LanguageModelSession(model: ParityModel.make())
        session.prewarm()
        let response = try await session.respond(
            to: "Reply with the single word: ready",
            options: deterministic
        )
        #expect(!response.content.isEmpty)
        #expect(session.isResponding == false)
    }
}

// MARK: - API parity (no model required — pure library semantics)

@Suite("API parity — pure library semantics")
struct APIParityScenarios {

    @Test("GeneratedContent round-trips JSON and exposes typed property access")
    func generatedContentJSONRoundTrip() throws {
        let content = try GeneratedContent(
            json: #"{"name": "Ada", "age": 36, "tags": ["pioneer", "mathematician"]}"#
        )

        let name: String = try content.value(String.self, forProperty: "name")
        let age: Int = try content.value(Int.self, forProperty: "age")
        let tags: [String] = try content.value([String].self, forProperty: "tags")
        #expect(name == "Ada")
        #expect(age == 36)
        #expect(tags == ["pioneer", "mathematician"])

        #expect(throws: (any Error).self) {
            let _: String = try content.value(String.self, forProperty: "missing")
        }
    }

    @Test("GeneratedContent built from properties serializes to JSON and parses back")
    func generatedContentPropertiesToJSON() throws {
        let content = GeneratedContent(properties: [
            "city": "Lagos",
            "population": 15_000_000,
        ])
        let parsed = try GeneratedContent(json: content.jsonString)

        let city: String = try parsed.value(String.self, forProperty: "city")
        let population: Int = try parsed.value(Int.self, forProperty: "population")
        #expect(city == "Lagos")
        #expect(population == 15_000_000)
    }

    @Test("GenerationOptions is value-equatable")
    func generationOptionsEquality() {
        #expect(GenerationOptions(temperature: 0.5) == GenerationOptions(temperature: 0.5))
        #expect(GenerationOptions(temperature: 0.5) != GenerationOptions(temperature: 0.9))
        #expect(GenerationOptions() == GenerationOptions())
        #expect(GenerationOptions(maximumResponseTokens: 10) != GenerationOptions())
    }

    @Test("Prompt and Instructions result builders accept multi-line string content")
    func promptAndInstructionsBuilders() throws {
        let prompt = Prompt {
            "You are given a task."
            "Complete it carefully."
        }
        _ = prompt

        let instructions = Instructions {
            "Be helpful."
        }
        _ = instructions
    }

    @Test("Transcript behaves as a RandomAccessCollection of entries")
    func transcriptCollectionSemantics() {
        let empty = Transcript()
        #expect(empty.isEmpty)

        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "hello"))]))
        ]
        let transcript = Transcript(entries: entries)
        #expect(transcript.count == 1)
        if case .prompt = transcript[transcript.startIndex] {} else {
            Issue.record("expected the first entry to be a prompt")
        }
    }
}

// MARK: - Shared test fixtures

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

struct ThermometerTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let recorder: CallRecorder

    var name: String { "currentTemperature" }
    var description: String { "Returns the current temperature in a city, in degrees celsius." }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "arguments",
            properties: [
                .init(
                    name: "city",
                    description: "Name of the city",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let city = (try? arguments.value(String.self, forProperty: "city")) ?? "unknown"
        recorder.record(city)
        return "The current temperature in \(city) is exactly 18 degrees celsius."
    }
}

#endif
