// Offline behavioral tests for LanguageModelSession concurrency, transcript
// management, the tool-call loop, and dynamic profiles — driven by a scripted
// in-process fake model, so no network or live model is needed.

import Foundation
import Testing
import ServerFoundationModels
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Scripted fake model

/// A signal another task can block on until it is opened.
final class ScriptGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func open() { continuation.finish() }

    func wait() async {
        for await _ in stream {}
    }
}

struct ScriptError: Error, Equatable {
    var message: String
}

enum ScriptedResponseEvent: Sendable {
    case addAttachment(Transcript.AttachmentSegment)
    case removeAttachment(id: String)
    case updateCustom(BehaviorCustomSegment)
}

/// One executor round the fake model plays back.
struct ScriptedRound: Sendable {
    var textFragments: [String] = []
    var reasoningFragments: [String] = []
    var reasoningSignature: Data?
    var responseEvents: [ScriptedResponseEvent] = []
    var toolCalls: [ScriptedToolCall] = []
    var usage: (input: Int, output: Int)?
    var failWith: ScriptError?
    var blockOn: ScriptGate?
}

struct ScriptedToolCall: Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// Records every executor request and plays back programmed rounds.
final class ScriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [ScriptedRound]
    private let repeatLastRound: Bool
    private var requests: [LanguageModelExecutorGenerationRequest] = []

    init(rounds: [ScriptedRound], repeatLastRound: Bool = false) {
        self.rounds = rounds
        self.repeatLastRound = repeatLastRound
    }

    func next(recording request: LanguageModelExecutorGenerationRequest) -> ScriptedRound? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if repeatLastRound, rounds.count == 1 { return rounds[0] }
        return rounds.isEmpty ? nil : rounds.removeFirst()
    }

    var recordedRequests: [LanguageModelExecutorGenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

struct ScriptedModel: LanguageModel {
    let script: ScriptBox

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling, .guidedGeneration])
    }

    var executorConfiguration: Executor.Configuration { Executor.Configuration() }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable {}

        init(configuration: Configuration) throws {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ScriptedModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            guard let round = model.script.next(recording: request) else {
                throw LanguageModelTransportError(statusCode: 0, message: "script exhausted")
            }
            if let gate = round.blockOn { await gate.wait() }
            for fragment in round.reasoningFragments {
                await channel.send(.reasoning(action: .appendText(fragment, tokenCount: 1)))
            }
            if let signature = round.reasoningSignature {
                await channel.send(.reasoning(action: .updateSignature(signature, tokenCount: 1)))
            }
            for event in round.responseEvents {
                switch event {
                case .addAttachment(let segment):
                    await channel.send(.response(action: .addAttachmentSegment(segment)))
                case .removeAttachment(let id):
                    await channel.send(.response(action: .removeAttachmentSegment(id: id)))
                case .updateCustom(let segment):
                    await channel.send(.response(action: .updateCustomSegment(segment)))
                }
            }
            for fragment in round.textFragments {
                await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
            }
            for call in round.toolCalls {
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id, name: call.name,
                    action: .appendArguments(call.argumentsJSON, tokenCount: 1)
                )))
            }
            if let usage = round.usage {
                await channel.send(.response(action: .updateUsage(
                    input: .init(totalTokenCount: usage.input, cachedTokenCount: 0),
                    output: .init(totalTokenCount: usage.output, reasoningTokenCount: 0)
                )))
            }
            if let failure = round.failWith { throw failure }
        }
    }
}

// MARK: - Fixtures

final class BehaviorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct BehaviorEchoTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let recorder = BehaviorRecorder()

    var name: String { "behaviorEcho" }
    var description: String { "Echoes the value." }

    var parameters: GenerationSchema {
        try! GenerationSchema(
            root: DynamicGenerationSchema(name: "arguments", properties: [
                .init(name: "value", schema: DynamicGenerationSchema(type: String.self))
            ]),
            dependencies: []
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let value = (try? arguments.value(String.self, forProperty: "value")) ?? ""
        recorder.record(value)
        return "echoed \(value)"
    }
}

private func segmentText(_ segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment in
        if case .text(let text) = segment { return text.content }
        return nil
    }.joined()
}

struct BehaviorCustomSegment: Transcript.CustomSegment, Equatable {
    struct Content: Codable, Equatable, Sendable {
        var value: String
    }

    let id: String
    var content: Content

    init(id: String, value: String) {
        self.id = id
        self.content = Content(value: value)
    }
}

private func behaviorTestAttachment(id: String) -> Transcript.AttachmentSegment {
    #if canImport(CoreGraphics)
    var pixel: UInt32 = 0xFF000000
    let data = Data(bytes: &pixel, count: 4)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    return Transcript.AttachmentSegment(id: id, content: .image(Transcript.ImageAttachment(image)))
    #else
    return Transcript.AttachmentSegment(
        id: id,
        content: .image(Transcript.ImageAttachment(data: Data([0x01])))
    )
    #endif
}

private func entryText(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .instructions(let value): return segmentText(value.segments)
    case .prompt(let value): return segmentText(value.segments)
    case .response(let value): return segmentText(value.segments)
    case .reasoning(let value): return segmentText(value.segments)
    case .toolCalls, .toolOutput: return ""
    }
}

private func seedHistory() -> [Transcript.Entry] {
    [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "old q1"))])),
        .response(Transcript.Response(segments: [.text(.init(content: "old a1"))])),
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "old q2"))])),
        .response(Transcript.Response(segments: [.text(.init(content: "old a2"))])),
    ]
}

extension SessionPropertyValues {
    @SessionPropertyEntry var behaviorTestFlavor: String = "vanilla"
}

struct BehaviorTwoInstructions: DynamicInstructions {
    var body: some DynamicInstructions {
        "Be terse"
        "Answer in French"
    }
}

// MARK: - Tests

@Suite("session behavior (scripted fake model)")
struct SessionBehaviorTests {

    // MARK: Streaming gate

    @Test("a concurrent stream throws concurrentRequests through the stream and never clears the in-flight request's flag")
    func concurrentStreamsAreRejected() async throws {
        let gate = ScriptGate()
        let script = ScriptBox(rounds: [
            ScriptedRound(textFragments: ["first"], blockOn: gate)
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))

        let first = session.streamResponse(to: "one")
        let firstTask = Task { try await first.collect().content }

        var spins = 0
        while !session.isResponding && spins < 400 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(session.isResponding)

        let second = session.streamResponse(to: "two")
        var sawConcurrentRequests = false
        do {
            _ = try await second.collect()
        } catch let error as LanguageModelSession.GenerationError {
            if case .concurrentRequests = error { sawConcurrentRequests = true }
        } catch {}
        #expect(sawConcurrentRequests, "the second stream must fail with GenerationError.concurrentRequests")

        // The rejected stream must not clear the first request's flag nor
        // touch the transcript.
        #expect(session.isResponding)
        #expect(!session.transcript.contains { entryText($0) == "two" })

        gate.open()
        let firstContent = try await firstTask.value
        #expect(firstContent == "first")
        #expect(!session.isResponding)
    }

    @Test("a failed stream with .revertTranscript removes the prompt entry")
    func failedStreamReverts() async throws {
        let script = ScriptBox(rounds: [
            ScriptedRound(failWith: ScriptError(message: "boom"))
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))
        session.transcriptErrorHandlingPolicy = .revertTranscript

        let stream = session.streamResponse(to: "doomed prompt")
        await #expect(throws: ScriptError.self) {
            _ = try await stream.collect()
        }
        #expect(!session.transcript.contains { entryText($0) == "doomed prompt" })
        #expect(!session.isResponding)
    }

    // MARK: Shrinking history transforms

    @Test("respond with a shrinking history transform does not trap and returns the turn's entries")
    func shrinkingTransformDoesNotTrap() async throws {
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["answer"])])
        let profile = LanguageModelSession.Profile { "sys" }
            .model(ScriptedModel(script: script))
            .historyTransform { entries in Array(entries.suffix(1)) }
        let session = LanguageModelSession(profile: profile, history: seedHistory())

        let response = try await session.respond(to: "new question")
        #expect(response.content == "answer")

        let turn = Array(response.transcriptEntries)
        #expect(turn.count == 2)
        #expect(entryText(turn.first ?? .response(Transcript.Response(segments: []))) == "new question")
        #expect(entryText(turn.last ?? .response(Transcript.Response(segments: []))) == "answer")

        // The transform's result is the persisted state: instructions + the
        // surviving prompt + the response.
        #expect(session.transcript.count == 3)
    }

    @Test("a failed respond after a shrinking transform still reverts the prompt")
    func failedRespondAfterShrinkReverts() async throws {
        let script = ScriptBox(rounds: [
            ScriptedRound(failWith: ScriptError(message: "boom"))
        ])
        let profile = LanguageModelSession.Profile { "sys" }
            .model(ScriptedModel(script: script))
            .historyTransform { entries in Array(entries.suffix(1)) }
        let session = LanguageModelSession(profile: profile, history: seedHistory())
        session.transcriptErrorHandlingPolicy = .revertTranscript

        await #expect(throws: ScriptError.self) {
            _ = try await session.respond(to: "new question")
        }
        #expect(!session.transcript.contains { entryText($0) == "new question" })
        #expect(!session.transcript.contains { entry in
            if case .prompt = entry { return true }
            return false
        })
    }

    // MARK: Tool-round text

    @Test("text preceding a tool call is preserved in the transcript and the final response")
    func toolRoundTextPreserved() async throws {
        let tool = BehaviorEchoTool()
        let script = ScriptBox(rounds: [
            ScriptedRound(
                textFragments: ["Let me check."],
                toolCalls: [ScriptedToolCall(id: "c1", name: "behaviorEcho", argumentsJSON: #"{"value":"x"}"#)]
            ),
            ScriptedRound(textFragments: ["Done."]),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script), tools: [tool])

        let response = try await session.respond(to: "go")
        #expect(response.content == "Let me check.\nDone.")
        #expect(tool.recorder.all == ["x"])

        let entries = Array(session.transcript)
        let preambleIndex = entries.firstIndex { entryText($0) == "Let me check." }
        let toolCallsIndex = entries.firstIndex { entry in
            if case .toolCalls = entry { return true }
            return false
        }
        #expect(preambleIndex != nil, "the pre-tool-call text must be persisted")
        #expect(toolCallsIndex != nil)
        if let preambleIndex, let toolCallsIndex {
            #expect(preambleIndex < toolCallsIndex, "the preamble precedes the tool calls")
        }
    }

    @Test("streaming snapshots never shrink across tool rounds")
    func streamingSnapshotsAreMonotonic() async throws {
        let tool = BehaviorEchoTool()
        let script = ScriptBox(rounds: [
            ScriptedRound(
                textFragments: ["Let ", "me ", "check."],
                toolCalls: [ScriptedToolCall(id: "c1", name: "behaviorEcho", argumentsJSON: #"{"value":"x"}"#)]
            ),
            ScriptedRound(textFragments: ["Do", "ne."]),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script), tools: [tool])

        var previous = ""
        var last = ""
        for try await snapshot in session.streamResponse(to: "go") {
            #expect(snapshot.content.hasPrefix(previous), "cumulative snapshots must never regress")
            previous = snapshot.content
            last = snapshot.content
        }
        #expect(last == "Let me check.\nDone.")
    }

    // MARK: Round cap

    @Test("a runaway tool loop is stopped at the round cap")
    func roundCapStopsRunawayLoop() async throws {
        let tool = BehaviorEchoTool()
        let script = ScriptBox(
            rounds: [
                ScriptedRound(toolCalls: [ScriptedToolCall(id: "c", name: "behaviorEcho", argumentsJSON: "{}")])
            ],
            repeatLastRound: true
        )
        let session = LanguageModelSession(model: ScriptedModel(script: script), tools: [tool])

        do {
            _ = try await session.respond(to: "loop forever")
            Issue.record("the runaway loop must throw")
        } catch let error as LanguageModelSession.SessionControlError {
            if case .toolLoopLimitReached(let limit) = error.reason {
                #expect(limit == 64)
            } else {
                Issue.record("expected toolLoopLimitReached")
            }
        }
        #expect(script.recordedRequests.count == 64)
        #expect(!session.isResponding)
    }

    // MARK: includeSchemaInPrompt

    @Test("includeSchemaInPrompt: false reaches the executor request")
    func includeSchemaInPromptIsThreaded() async throws {
        let script = ScriptBox(rounds: [
            ScriptedRound(textFragments: [#""ok""#]),
            ScriptedRound(textFragments: [#""ok""#]),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))

        _ = try await session.respond(
            to: "q", schema: String.generationSchema, includeSchemaInPrompt: false
        )
        #expect(script.recordedRequests.count == 1)
        #expect(script.recordedRequests.first?.contextOptions.includeSchemaInPrompt == false)

        _ = try await session.streamResponse(
            to: "q2", schema: String.generationSchema, includeSchemaInPrompt: false
        ).collect()
        #expect(script.recordedRequests.count == 2)
        #expect(script.recordedRequests.last?.contextOptions.includeSchemaInPrompt == false)
    }

    // MARK: Prompt-overload forwarding

    @Test("streamResponse(to: Prompt) forwards contextOptions and metadata")
    func promptOverloadForwardsArguments() async throws {
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["hi"])])
        let session = LanguageModelSession(model: ScriptedModel(script: script))

        let stream = session.streamResponse(
            to: Prompt("question"),
            options: GenerationOptions(),
            contextOptions: ContextOptions(reasoningLevel: .deep),
            metadata: ["origin": "behavior-test"]
        )
        _ = try await stream.collect()

        let request = script.recordedRequests.first
        #expect(request?.contextOptions.reasoningLevel == .deep)
        #expect(request?.metadata["origin"] as? String == "behavior-test")
    }

    // MARK: Plain stream terminal snapshot

    @Test("plain stream collect() reports usage and succeeds for tool-only responses")
    func plainStreamCollectReportsUsage() async throws {
        let tool = BehaviorEchoTool()
        let script = ScriptBox(rounds: [
            ScriptedRound(
                toolCalls: [ScriptedToolCall(id: "c1", name: "behaviorEcho", argumentsJSON: #"{"value":"x"}"#)],
                usage: (input: 5, output: 7)
            ),
            ScriptedRound(usage: (input: 11, output: 13)),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script), tools: [tool])

        let response = try await session.streamResponse(to: "do it").collect()
        #expect(response.content == "")
        #expect(response.usage.input.totalTokenCount == 16)
        #expect(response.usage.output.totalTokenCount == 20)
        #expect(!response.transcriptEntries.isEmpty)
    }

    // MARK: Instruction joining

    @Test("multiple instruction texts join with a newline")
    func instructionsJoinWithNewline() async throws {
        // Profile-based session.
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["ok"])])
        let profile = LanguageModelSession.Profile {
            "Be terse"
            "Answer in French"
        }.model(ScriptedModel(script: script))
        let session = LanguageModelSession(profile: profile)
        _ = try await session.respond(to: "q")

        let request = try #require(script.recordedRequests.first)
        let instructions = request.transcript.first { entry in
            if case .instructions = entry { return true }
            return false
        }
        #expect(entryText(try #require(instructions)) == "Be terse\nAnswer in French")

        // Standalone dynamic-instructions session.
        let script2 = ScriptBox(rounds: [ScriptedRound(textFragments: ["ok"])])
        let session2 = LanguageModelSession(
            model: ScriptedModel(script: script2),
            dynamicInstructions: BehaviorTwoInstructions()
        )
        _ = try await session2.respond(to: "q")
        let request2 = try #require(script2.recordedRequests.first)
        let instructions2 = request2.transcript.first { entry in
            if case .instructions = entry { return true }
            return false
        }
        #expect(entryText(try #require(instructions2)) == "Be terse\nAnswer in French")
    }

    // MARK: inputFilter vs historyTransform persistence

    @Test("inputFilter shapes only the request transcript; historyTransform persists")
    func inputFilterIsNotPersisted() async throws {
        // inputFilter: the request sees the filtered copy, the session keeps
        // its full history.
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["a1"])])
        let profile = LanguageModelSession.Profile { "sys" }
            .model(ScriptedModel(script: script))
            .inputFilter { entries in Array(entries.suffix(1)) }
        let session = LanguageModelSession(profile: profile, history: seedHistory())

        _ = try await session.respond(to: "new question")
        let request = try #require(script.recordedRequests.first)
        #expect(request.transcript.count == 2, "instructions + the one filtered entry")
        // instructions + 4 seeded entries + prompt + response, all retained
        #expect(session.transcript.count == 7)
        #expect(session.transcript.contains { entryText($0) == "old q1" })

        // historyTransform: deliberately persisted.
        let script2 = ScriptBox(rounds: [ScriptedRound(textFragments: ["a2"])])
        let profile2 = LanguageModelSession.Profile { "sys" }
            .model(ScriptedModel(script: script2))
            .historyTransform { entries in Array(entries.suffix(1)) }
        let session2 = LanguageModelSession(profile: profile2, history: seedHistory())

        _ = try await session2.respond(to: "new question")
        #expect(session2.transcript.count == 3, "instructions + prompt + response")
        #expect(!session2.transcript.contains { entryText($0) == "old q1" })
    }

    // MARK: Session properties outside a binding

    @Test("prompt transcript entry carries contextOptions from respond")
    func promptTranscriptCarriesContextOptions() async throws {
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["ok"])])
        let session = LanguageModelSession(model: ScriptedModel(script: script))
        let contextOptions = ContextOptions(reasoningLevel: .deep)
        _ = try await session.respond(to: "q", contextOptions: contextOptions)

        let promptEntry = session.transcript.last { entry in
            if case .prompt = entry { return true }
            return false
        }
        guard case .prompt(let prompt) = promptEntry else {
            Issue.record("expected a prompt transcript entry")
            return
        }
        #expect(prompt.contextOptions.reasoningLevel == .deep)
    }

    @Test("unregistered tool call throws ToolCallError, not a transport error")
    func unregisteredToolThrowsToolCallError() async throws {
        let script = ScriptBox(rounds: [
            ScriptedRound(toolCalls: [
                ScriptedToolCall(id: "c1", name: "missingTool", argumentsJSON: "{}"),
            ]),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))

        do {
            _ = try await session.respond(to: "go")
            Issue.record("expected ToolCallError")
        } catch let error as LanguageModelSession.ToolCallError {
            #expect(error.tool.name == "missingTool")
            #expect(!(error.underlyingError is LanguageModelTransportError))
        }
    }

    @Test("reasoning signature from updateSignature lands in the transcript")
    func reasoningSignatureLandsInTranscript() async throws {
        let signature = Data([0x01, 0x02, 0x03])
        let script = ScriptBox(rounds: [
            ScriptedRound(
                reasoningFragments: ["thinking"],
                reasoningSignature: signature,
                textFragments: ["answer"]
            ),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))
        _ = try await session.respond(to: "q")

        let reasoningEntry = session.transcript.first { entry in
            if case .reasoning = entry { return true }
            return false
        }
        guard let reasoningEntry, case .reasoning(let reasoning) = reasoningEntry else {
            Issue.record("expected a reasoning transcript entry")
            return
        }
        #expect(reasoning.signature == signature)
        #expect(entryText(reasoningEntry) == "thinking")
    }

    @Test("custom segment index stays valid after attachment removal")
    func customSegmentSurvivesAttachmentRemoval() async throws {
        let script = ScriptBox(rounds: [
            ScriptedRound(
                responseEvents: [
                    .addAttachment(behaviorTestAttachment(id: "A")),
                    .updateCustom(BehaviorCustomSegment(id: "C", value: "initial")),
                    .removeAttachment(id: "A"),
                    .updateCustom(BehaviorCustomSegment(id: "C", value: "updated")),
                ],
                textFragments: ["done"]
            ),
        ])
        let session = LanguageModelSession(model: ScriptedModel(script: script))
        _ = try await session.respond(to: "q")

        let responseEntry = session.transcript.last { entry in
            if case .response = entry { return true }
            return false
        }
        guard case .response(let response) = responseEntry else {
            Issue.record("expected a response transcript entry")
            return
        }

        let customSegments = response.segments.compactMap { segment -> BehaviorCustomSegment? in
            guard case .custom(let custom) = segment else { return nil }
            return custom as? BehaviorCustomSegment
        }
        #expect(customSegments.count == 1)
        #expect(customSegments[0].content.value == "updated")
        #expect(!response.segments.contains { segment in
            if case .attachment = segment { return true }
            return false
        })
    }

    @Test("single-line fenced JSON decodes on typed respond")
    func singleLineFenceDecodesOnTypedRespond() async throws {
        let script = ScriptBox(rounds: [ScriptedRound(textFragments: ["```42```"])])
        let session = LanguageModelSession(model: ScriptedModel(script: script))
        let response = try await session.respond(to: "q", generating: Int.self)
        #expect(response.content == 42)
    }

    @Test("a @SessionProperty write outside any session binding is dropped, not leaked")
    func orphanSessionPropertyWriteDoesNotLeak() async throws {
        let property = LanguageModelSession.SessionProperty(\.behaviorTestFlavor)

        // Outside any session binding: the write must be dropped...
        property.wrappedValue = "leaked"
        // ...so a later read in this context returns the default...
        #expect(property.wrappedValue == "vanilla")

        // ...and so does a read from an unrelated detached task, which on the
        // old shared-orphan fallback would have observed "leaked".
        let observed = await Task.detached {
            LanguageModelSession.SessionProperty(\.behaviorTestFlavor).wrappedValue
        }.value
        #expect(observed == "vanilla")

        // A real session's storage is untouched as well.
        let session = LanguageModelSession(model: ScriptedModel(script: ScriptBox(rounds: [])))
        #expect(session.properties.behaviorTestFlavor == "vanilla")
    }
}
