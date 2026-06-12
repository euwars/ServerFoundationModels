// Wire-level proof that everything the API promises actually leaves the
// process: instructions as the system message, @Generable schemas (with
// @Guide descriptions, enums, and bounds) as response_format, tool
// definitions with their parameter schemas, and generation options.
//
// A loopback HTTP server captures the exact request body produced by
// ChatCompletionsLanguageModel and returns a canned SSE response.

import Foundation
import Testing
import LinuxFoundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Wire capture — outgoing request contents")
struct WireCaptureTests {

    @Test("instructions, tools, schema, and options all appear in the outgoing body")
    func everythingGoesOut() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        let recorder = CallRecorder()
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!,
            additionalHeaders: ["Authorization": "Bearer wire-test"]
        )
        let session = LanguageModelSession(
            model: model,
            tools: [ThermometerTool(recorder: recorder)],
            instructions: "You are the wire-capture assistant."
        )

        _ = try await session.respond(
            to: "Suggest a craft idea.",
            generating: CraftIdea.self,
            options: GenerationOptions(temperature: 0.25, maximumResponseTokens: 321)
        )

        let body = try #require(server.lastBody, "the request body must be captured")
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        // Model + options
        #expect(json["model"] as? String == "wire-model")
        #expect(json["temperature"] as? Double == 0.25)
        #expect(json["max_tokens"] as? Int == 321)
        #expect((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)

        // Instructions become the system message, verbatim.
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "You are the wire-capture assistant.")
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "Suggest a craft idea.")

        // Tool definitions carry their parameter schemas.
        let tools = try #require(json["tools"] as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "currentTemperature")
        #expect((function["description"] as? String)?.isEmpty == false)
        let toolParams = try #require(function["parameters"] as? [String: Any])
        let toolProps = try #require(toolParams["properties"] as? [String: Any])
        #expect(toolProps["city"] != nil)

        // The @Generable schema rides response_format with @Guide content.
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(schema["description"] as? String == "A craft project idea")
        let properties = try #require(schema["properties"] as? [String: Any])
        let title = try #require(properties["title"] as? [String: Any])
        #expect(title["description"] as? String == "Short title for the idea")
        let category = try #require(properties["category"] as? [String: Any])
        #expect((category["enum"] as? [String])?.contains("origami project") == true)
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["title", "category"])

        // Auth header reached the wire too.
        #expect(server.lastHeaders["authorization"] == "Bearer wire-test")
    }

    @Test("every scalar kind, optionals, and enums land in the wire schema")
    func kitchenSinkSchemaGoesOut() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        let session = LanguageModelSession(model: ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!
        ))
        _ = try? await session.respond(
            to: "record",
            generating: KitchenSink.self,
            options: GenerationOptions(temperature: 0)
        )

        let body = try #require(server.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responseFormat = try #require(json["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        let schema = try #require(jsonSchema["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect((properties["isActive"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((properties["isActive"] as? [String: Any])?["description"] as? String == "Whether the record is active")
        #expect((properties["count"] as? [String: Any])?["type"] as? String == "integer")
        #expect((properties["ratio"] as? [String: Any])?["type"] as? String == "number")
        #expect((properties["weight"] as? [String: Any])?["type"] as? String == "number")
        #expect((properties["price"] as? [String: Any])?["type"] as? String == "number")
        #expect((properties["nickname"] as? [String: Any])?["type"] as? String == "string")

        // A raw-value-less enum serializes its case names.
        let mood = try #require(properties["mood"] as? [String: Any])
        #expect((mood["enum"] as? [String])?.sorted() == ["excited", "neutral", "skeptical"])
        let pastMoods = try #require(properties["pastMoods"] as? [String: Any])
        #expect(pastMoods["type"] as? String == "array")
        #expect(((pastMoods["items"] as? [String: Any])?["enum"] as? [String])?.contains("neutral") == true)

        // Optionals are present as properties but excluded from `required`.
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["isActive", "count", "ratio", "weight", "price", "mood", "pastMoods"])
    }

    @Test("guide bounds (minimum/maximum/minItems/maxItems) reach the schema on the wire")
    func guideBoundsGoOut() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        let session = LanguageModelSession(model: ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "http://127.0.0.1:\(server.port)")!
        ))
        _ = try? await session.respond(
            to: "plan",
            generating: TravelPlan.self,
            options: GenerationOptions(temperature: 0)
        )

        let body = try #require(server.lastBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""minimum":1"#), "TravelDay.dayNumber @Guide(.minimum(1))")
        #expect(text.contains(#""minimum":15"#) && text.contains(#""maximum":240"#), ".range(15...240)")
        #expect(text.contains(#""minItems":1"#), ".minimumCount(1) on activities")
        #expect(text.contains(#""minItems":2"#) && text.contains(#""maxItems":2"#), ".count(2) on days")
    }
}

// MARK: - Loopback capture server

/// A minimal blocking HTTP/1.1 server on a background thread: captures one
/// request at a time and answers with a canned SSE chat completion.
final class CaptureServer: @unchecked Sendable {
    private let socket: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _lastBody: Data?
    private var _lastHeaders: [String: String] = [:]
    private var running = true

    var lastBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _lastBody
    }

    var lastHeaders: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return _lastHeaders
    }

    init() throws {
        let fd = Foundation.socket(AF_INET, SOCK_STREAM_VALUE, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            throw CaptureError(message: "could not bind loopback server")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        socket = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self.handle(client: client)
                close(client)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        close(socket)
    }

    private func handle(client: Int32) {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var contentLength = 0
        var headerEnd: Int?
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                var headers: [String: String] = [:]
                for line in head.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                contentLength = Int(headers["content-length"] ?? "0") ?? 0
                lock.lock()
                _lastHeaders = headers
                lock.unlock()
            }
            if let headerEnd, data.count - headerEnd >= contentLength {
                lock.lock()
                _lastBody = data.suffix(from: headerEnd)
                lock.unlock()
                break
            }
        }

        let payload = #"{"choices":[{"index":0,"delta":{"content":"{\"title\": \"Crane\", \"category\": \"origami project\"}"}}]}"#
        let sse = "data: \(payload)\n\ndata: [DONE]\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(sse.utf8.count)\r\nConnection: close\r\n\r\n\(sse)"
        _ = response.withCString { pointer in
            write(client, pointer, response.utf8.count)
        }
    }

    struct CaptureError: Error {
        let message: String
    }
}

#if canImport(Darwin)
private let SOCK_STREAM_VALUE = SOCK_STREAM
#else
private let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#endif
