// Offline fidelity proofs for Transcript Codable round-trips, equality
// semantics (contextOptions/metadata), history set-then-get, prompt-builder
// blank-line suppression, and attachment failure surfacing.

import Foundation
import Testing
@testable import ServerFoundationModels

#if canImport(CoreImage)
import CoreImage
import ImageIO
#endif

@Suite("Transcript fidelity")
struct TranscriptFidelityTests {

    // MARK: Helpers

    /// Order-insensitive JSON comparison (key order may change across a
    /// schema round-trip because decoded raw documents sort keys).
    private func jsonValue(_ string: String) throws -> NSObject {
        let data = try #require(string.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try #require(object as? NSObject)
    }

    private func makeFullTranscript() throws -> Transcript {
        let toolSchema = GenerationSchema(type: String.self, description: "a choice", anyOf: ["red", "green"])
        let instructions = Transcript.Instructions(
            id: "ins-1",
            segments: [.text(.init(id: "seg-ins-1", content: "You are terse."))],
            toolDefinitions: [
                .init(name: "paint", description: "Paints things", parameters: toolSchema)
            ]
        )

        let options = GenerationOptions(
            samplingMode: .random(top: 40, seed: 7),
            temperature: 0.5,
            maximumResponseTokens: 256,
            toolCallingMode: .required
        )
        let prompt = Transcript.Prompt(
            id: "prm-1",
            segments: [
                .text(.init(id: "seg-prm-1", content: "Hello")),
                .structure(.init(id: "seg-prm-2", source: "Widget", content: try GeneratedContent(json: #"{"a":1}"#))),
            ],
            options: options,
            responseFormat: .init(schema: toolSchema),
            contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: .custom("think hard"))
        )

        let reasoning = Transcript.Reasoning(
            id: "rsn-1",
            segments: [.text(.init(id: "seg-rsn-1", content: "thinking..."))],
            signature: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        let toolCalls = Transcript.ToolCalls(id: "tcs-1", [
            Transcript.ToolCall(
                id: "tc-1",
                toolName: "paint",
                arguments: try GeneratedContent(json: #"{"color":"red"}"#)
            )
        ])

        let toolOutput = Transcript.ToolOutput(
            id: "out-1",
            toolName: "paint",
            segments: [
                .text(.init(id: "seg-out-1", content: "painted")),
                .structure(.init(id: "seg-out-2", source: "Result", content: try GeneratedContent(json: #"{"ok":true}"#))),
            ]
        )

        let response = Transcript.Response(
            id: "rsp-1",
            assetIDs: ["asset-1", "asset-2"],
            segments: [.text(.init(id: "seg-rsp-1", content: "Done"))]
        )

        return Transcript(entries: [
            .instructions(instructions),
            .prompt(prompt),
            .reasoning(reasoning),
            .toolCalls(toolCalls),
            .toolOutput(toolOutput),
            .response(response),
        ])
    }

    // MARK: Codable round-trip

    @Test("encode -> decode preserves every field and segment ID")
    func fullRoundTrip() throws {
        let original = try makeFullTranscript()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        #expect(decoded.count == original.count)

        // Instructions: id, segment ids/content, toolDefinitions.
        guard case .instructions(let ins) = decoded[0], case .instructions(let originalIns) = original[0] else {
            Issue.record("expected instructions at [0]")
            return
        }
        #expect(ins.id == "ins-1")
        #expect(ins.segments == originalIns.segments)
        #expect(ins.segments.map(\.id) == ["seg-ins-1"])
        #expect(ins.toolDefinitions.count == 1)
        let tool = try #require(ins.toolDefinitions.first)
        #expect(tool.name == "paint")
        #expect(tool.description == "Paints things")
        // Schema round-trips as the same JSON Schema document (key order may
        // differ, so compare parsed JSON).
        try #expect(
            jsonValue(tool.parameters.debugDescription)
                == jsonValue(originalIns.toolDefinitions[0].parameters.debugDescription)
        )

        // Prompt: id, segments (text + structure) with ids, options,
        // responseFormat, contextOptions.
        guard case .prompt(let prm) = decoded[1], case .prompt(let originalPrm) = original[1] else {
            Issue.record("expected prompt at [1]")
            return
        }
        #expect(prm.id == "prm-1")
        #expect(prm.segments == originalPrm.segments)
        #expect(prm.segments.map(\.id) == ["seg-prm-1", "seg-prm-2"])
        #expect(prm.options == originalPrm.options)
        #expect(prm.options.temperature == 0.5)
        #expect(prm.options.maximumResponseTokens == 256)
        #expect(prm.options.samplingMode == .random(top: 40, seed: 7))
        #expect(prm.options.toolCallingMode == .required)
        #expect(prm.contextOptions == originalPrm.contextOptions)
        #expect(prm.contextOptions.includeSchemaInPrompt == true)
        #expect(prm.contextOptions.reasoningLevel == .custom("think hard"))
        let format = try #require(prm.responseFormat)
        let originalFormat = try #require(originalPrm.responseFormat)
        #expect(format.name == originalFormat.name)

        // Reasoning: id, segments, signature.
        guard case .reasoning(let rsn) = decoded[2] else {
            Issue.record("expected reasoning at [2]")
            return
        }
        #expect(rsn.id == "rsn-1")
        #expect(rsn.segments.map(\.id) == ["seg-rsn-1"])
        #expect(rsn.signature == Data([0xDE, 0xAD, 0xBE, 0xEF]))

        // Tool calls: ids, names, arguments.
        guard case .toolCalls(let tcs) = decoded[3], case .toolCalls(let originalTcs) = original[3] else {
            Issue.record("expected toolCalls at [3]")
            return
        }
        #expect(tcs.id == "tcs-1")
        #expect(Array(tcs) == Array(originalTcs))

        // Tool output: id, toolName, segments with ids.
        guard case .toolOutput(let out) = decoded[4], case .toolOutput(let originalOut) = original[4] else {
            Issue.record("expected toolOutput at [4]")
            return
        }
        #expect(out.id == "out-1")
        #expect(out.toolName == "paint")
        #expect(out.segments == originalOut.segments)
        #expect(out.segments.map(\.id) == ["seg-out-1", "seg-out-2"])

        // Response: id, assetIDs, segments.
        guard case .response(let rsp) = decoded[5], case .response(let originalRsp) = original[5] else {
            Issue.record("expected response at [5]")
            return
        }
        #expect(rsp.id == "rsp-1")
        #expect(rsp.assetIDs == ["asset-1", "asset-2"])
        #expect(rsp.segments == originalRsp.segments)
        #expect(rsp.segments.map(\.id) == ["seg-rsp-1"])
    }

    @Test("a second encode of the decoded transcript is stable")
    func reEncodeStability() throws {
        let original = try makeFullTranscript()
        let once = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: once)
        let twice = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(Transcript.self, from: twice)
        #expect(again.map(\.id) == original.map(\.id))
    }

    // MARK: Legacy flat format

    @Test("decoding the old flat role/id/text format still works")
    func legacyFlatFormatDecodes() throws {
        let legacy = """
        [
          {"role": "instructions", "id": "ins-legacy", "text": "Be brief."},
          {"role": "prompt", "id": "prm-legacy", "text": "Hi there"},
          {"role": "toolCalls", "id": "tcs-legacy", "calls": [
            {"id": "tc-legacy", "toolName": "paint", "arguments": "{\\"color\\":\\"red\\"}"}
          ]},
          {"role": "toolOutput", "id": "out-legacy", "toolName": "paint", "text": "painted"},
          {"role": "reasoning", "id": "rsn-legacy", "text": "hmm"},
          {"role": "response", "id": "rsp-legacy", "text": "Hello!"}
        ]
        """
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
        #expect(decoded.map(\.id) == [
            "ins-legacy", "prm-legacy", "tcs-legacy", "out-legacy", "rsn-legacy", "rsp-legacy",
        ])
        guard case .instructions(let ins) = decoded[0] else {
            Issue.record("expected instructions")
            return
        }
        #expect(ins.segments.joinedText == "Be brief.")
        #expect(ins.toolDefinitions.isEmpty)
        guard case .prompt(let prm) = decoded[1] else {
            Issue.record("expected prompt")
            return
        }
        #expect(prm.segments.joinedText == "Hi there")
        guard case .toolCalls(let tcs) = decoded[2] else {
            Issue.record("expected toolCalls")
            return
        }
        #expect(tcs.first?.toolName == "paint")
        #expect(tcs.first?.arguments.jsonString == #"{"color":"red"}"#)
        guard case .toolOutput(let out) = decoded[3] else {
            Issue.record("expected toolOutput")
            return
        }
        #expect(out.toolName == "paint")
        #expect(out.segments.joinedText == "painted")
        guard case .response(let rsp) = decoded[5] else {
            Issue.record("expected response")
            return
        }
        #expect(rsp.segments.joinedText == "Hello!")
    }

    // MARK: Equality semantics

    @Test("Prompt == distinguishes contextOptions")
    func promptEqualityIncludesContextOptions() {
        let segments: [Transcript.Segment] = [.text(.init(id: "s", content: "hi"))]
        let a = Transcript.Prompt(
            id: "p", segments: segments, options: .init(), responseFormat: nil,
            contextOptions: ContextOptions(includeSchemaInPrompt: true)
        )
        var b = a
        #expect(a == b)
        b.contextOptions = ContextOptions(includeSchemaInPrompt: false)
        #expect(a != b)
    }

    @Test("Response == distinguishes metadata")
    func responseEqualityIncludesMetadata() {
        let segments: [Transcript.Segment] = [.text(.init(id: "s", content: "hi"))]
        let a = Transcript.Response(id: "r", metadata: ["k": "v"], segments: segments)
        var b = a
        #expect(a == b)
        b.metadata = ["k": "other"]
        #expect(a != b)
        b.metadata = ["k": 42]  // same key, different erased type
        #expect(a != b)
        b.metadata = ["k": "v"]
        #expect(a == b)
        b.metadata = [:]
        #expect(a != b)
    }

    @Test("ToolCall and Reasoning == distinguish metadata")
    func toolCallAndReasoningEqualityIncludeMetadata() throws {
        let args = try GeneratedContent(json: #"{"x":1}"#)
        let callA = Transcript.ToolCall(id: "c", metadata: ["m": 1], toolName: "t", arguments: args)
        var callB = callA
        #expect(callA == callB)
        callB.metadata = ["m": 2]
        #expect(callA != callB)

        let reasonA = Transcript.Reasoning(
            id: "r", metadata: ["m": true], segments: [.text(.init(id: "s", content: "x"))]
        )
        var reasonB = reasonA
        #expect(reasonA == reasonB)
        reasonB.metadata = ["m": false]
        #expect(reasonA != reasonB)
    }

    // MARK: history semantics

    @Test("history set-then-get: leading instructions in the assigned value are absorbed into the prefix")
    func historySetThenGet() {
        let instructions = Transcript.Entry.instructions(
            .init(id: "ins-a", segments: [.text(.init(id: "s1", content: "base"))], toolDefinitions: [])
        )
        let oldPrompt = Transcript.Entry.prompt(.init(id: "old-p", segments: [.text(.init(id: "s2", content: "old"))]))
        var transcript = Transcript(entries: [instructions, oldPrompt])

        let newInstructions = Transcript.Entry.instructions(
            .init(id: "ins-b", segments: [.text(.init(id: "s3", content: "extra"))], toolDefinitions: [])
        )
        let newPrompt = Transcript.Entry.prompt(.init(id: "new-p", segments: [.text(.init(id: "s4", content: "new"))]))
        let newResponse = Transcript.Entry.response(.init(id: "new-r", segments: [.text(.init(id: "s5", content: "ok"))]))

        transcript.history = [newInstructions, newPrompt, newResponse][...]

        // The leading instructions entry was absorbed into the instructions
        // prefix; the getter returns only the conversation that follows it.
        #expect(transcript.history.map(\.id) == ["new-p", "new-r"])
        // Nothing was lost: the full entry list keeps both instruction
        // entries ahead of the conversation.
        #expect(transcript.map(\.id) == ["ins-a", "ins-b", "new-p", "new-r"])

        // Assigning a value with no instructions round-trips exactly.
        transcript.history = [newPrompt, newResponse][...]
        #expect(Array(transcript.history) == [newPrompt, newResponse])
    }

    // MARK: Prompt/Instructions builders

    @Test("a false `if` does not inject a blank line into a built prompt")
    func promptBuilderFalseOptional() {
        let include = false
        let prompt = Prompt {
            "a"
            if include { "c" }
            "b"
        }
        #expect(prompt.text == "a\nb")

        let instructions = Instructions {
            "a"
            if include { "c" }
            "b"
        }
        #expect(instructions.text == "a\nb")
    }

    @Test("an empty buildArray contributes nothing")
    func promptBuilderEmptyArray() {
        let items: [String] = []
        let prompt = Prompt {
            "a"
            for item in items { item }
            "b"
        }
        #expect(prompt.text == "a\nb")
    }

    @Test("a true `if` still contributes its line")
    func promptBuilderTrueOptional() {
        let include = true
        let prompt = Prompt {
            "a"
            if include { "c" }
            "b"
        }
        #expect(prompt.text == "a\nc\nb")
    }

    // MARK: Attachment failure surfacing

    #if canImport(CoreImage)
    @Test("Attachment(contentsOf:) throws for a missing file; the non-throwing init surfaces loadError")
    func attachmentFailureSurfacing() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")

        #expect(throws: (any Error).self) {
            _ = try Attachment<ImageAttachmentContent>(contentsOf: missing)
        }

        let fallback = Attachment<ImageAttachmentContent>(imageURL: missing)
        #expect(fallback.loadError != nil)
        #expect(fallback.content.data.isEmpty)
    }

    @Test("Attachment(contentsOf:) loads bytes and stores orientation")
    func attachmentSuccessStoresOrientation() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fidelity-\(UUID().uuidString).bin")
        let payload = Data([1, 2, 3, 4])
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = try Attachment<ImageAttachmentContent>(contentsOf: url, orientation: .left)
        #expect(attachment.content.data == payload)
        #expect(attachment.content.orientation == .left)
        #expect(attachment.loadError == nil)
    }
    #endif

    @Test("ImageReference throws when attachmentLabel is missing")
    func imageReferenceMissingLabelThrows() throws {
        let empty = try GeneratedContent(json: "{}")
        #expect(throws: (any Error).self) {
            _ = try ImageReference(empty)
        }
        let labeled = try GeneratedContent(json: #"{"attachmentLabel":"photo"}"#)
        let reference = try ImageReference(labeled)
        #expect(reference.attachmentLabel == "photo")
    }
}
