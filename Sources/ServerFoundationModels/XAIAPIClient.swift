// xAI Responses API wire types and HTTP transport.

import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct XAIResponsesRequest: Sendable {
    var model: String
    var reasoning: XAIReasoningEffort?
    var instructions: String?
    var inputItems: [JSONNode]
    var prebuiltInputJSON: Data?
    var tools: [JSONNode]
    var store: Bool = true
    var textFormat: JSONNode?
    var previousResponseId: String?
    var temperature: Double?
    var maxOutputTokens: Int?
    var promptCacheKey: String?
    var stream: Bool = true
    var include: [String] = []

    func bodyJSON() throws -> Data {
        Data(serialize().utf8)
    }

    func serialize() -> String {
        var members: [JSONNode.Member] = [
            .init(key: "model", value: .string(model)),
            .init(key: "store", value: .bool(store)),
        ]

        if let reasoning {
            members.append(.init(key: "reasoning", value: .object([
                .init(key: "effort", value: .string(reasoning.rawValue)),
            ])))
        }
        if let instructions {
            members.append(.init(key: "instructions", value: .string(instructions)))
        }

        if let prebuiltInputJSON,
            let array = try? JSONSerialization.jsonObject(with: prebuiltInputJSON) as? [Any] {
            members.append(.init(key: "input", value: .array(array.map { anyToJSONNode($0) })))
        } else {
            members.append(.init(key: "input", value: .array(inputItems)))
        }

        if !tools.isEmpty {
            members.append(.init(key: "tools", value: .array(tools)))
        }
        if let textFormat {
            members.append(.init(key: "text", value: textFormat))
        }
        if let previousResponseId {
            members.append(.init(key: "previous_response_id", value: .string(previousResponseId)))
        }
        if let temperature {
            members.append(.init(key: "temperature", value: .number(temperature)))
        }
        if let maxOutputTokens {
            members.append(.init(key: "max_output_tokens", value: .integer(maxOutputTokens)))
        }
        if let promptCacheKey {
            members.append(.init(key: "prompt_cache_key", value: .string(promptCacheKey)))
        }
        if stream {
            members.append(.init(key: "stream", value: .bool(true)))
        }
        if !include.isEmpty {
            members.append(.init(key: "include", value: .array(include.map { .string($0) })))
        }

        return JSONNode.object(members).serialized
    }
}

struct XAIResponsesBody: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

enum XAIHTTPClient {
    static func post(_ request: URLRequest, logger: Logger) async throws -> XAIResponsesBody {
        logger.debug("xai.responses request", metadata: [
            "host": .string(request.url?.host ?? "?"),
            "method": .string(request.httpMethod ?? "POST"),
        ])

        #if AsyncHTTPClient
        return try await postViaAsyncHTTPClient(request)
        #elseif canImport(Darwin)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LanguageModelTransportError(statusCode: 0, message: "non-HTTP response")
        }
        return XAIResponsesBody(
            data: data,
            statusCode: http.statusCode,
            headers: Dictionary(http.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let key = key as? String, let value = value as? String else { return nil }
                return (key, value)
            }, uniquingKeysWith: { first, _ in first })
        )
        #else
        return try await postViaLinuxSession(request)
        #endif
    }

    #if !canImport(Darwin) && !AsyncHTTPClient
    private static func postViaLinuxSession(_ request: URLRequest) async throws -> XAIResponsesBody {
        let (handler, task) = LinuxDataSession.shared.register(request)
        task.resume()
        let response = try await handler.response()
        let data = try await handler.collectBody()
        return XAIResponsesBody(
            data: data,
            statusCode: response.statusCode,
            headers: Dictionary(response.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let key = key as? String, let value = value as? String else { return nil }
                return (key, value)
            }, uniquingKeysWith: { first, _ in first })
        )
    }
    #endif
}

#if !canImport(Darwin) && !AsyncHTTPClient
final class LinuxDataSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LinuxDataSession()

    private let lock = NSLock()
    private var handlers: [Int: DataStreamDelegate] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func register(_ request: URLRequest) -> (DataStreamDelegate, URLSessionDataTask) {
        let handler = DataStreamDelegate()
        let task = session.dataTask(with: request)
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
        handler.onTerminate = { [weak task] in task?.cancel() }
        return (handler, task)
    }

    private func handler(for task: URLSessionTask) -> DataStreamDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        handler(for: dataTask)?.receive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let finished = handler(for: task)
        lock.lock()
        handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        finished?.complete(error: error)
    }
}

final class DataStreamDelegate: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    private var storedResponse: HTTPURLResponse?
    private var bodyContinuation: CheckedContinuation<Data, any Error>?
    private var finishedEarly: (any Error)?

    var onTerminate: (@Sendable () -> Void)?

    func response() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let storedResponse {
                    lock.unlock()
                    continuation.resume(returning: storedResponse)
                } else if let finishedEarly {
                    lock.unlock()
                    continuation.resume(throwing: finishedEarly)
                } else {
                    responseContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            onTerminate?()
        }
    }

    func collectBody() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                bodyContinuation = continuation
                if let finishedEarly {
                    let error = finishedEarly
                    bodyContinuation = nil
                    lock.unlock()
                    continuation.resume(throwing: error)
                } else {
                    lock.unlock()
                }
            }
        } onCancel: {
            onTerminate?()
        }
    }

    func receive(response: URLResponse) {
        lock.lock()
        storedResponse = response as? HTTPURLResponse
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        if let continuation {
            if let http = response as? HTTPURLResponse {
                continuation.resume(returning: http)
            } else {
                continuation.resume(throwing: LanguageModelTransportError(
                    statusCode: 0, message: "non-HTTP response"
                ))
            }
        }
    }

    func receive(data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func complete(error: (any Error)?) {
        lock.lock()
        let body = buffer
        let continuation = bodyContinuation
        bodyContinuation = nil
        let responseContinuation = responseContinuation
        self.responseContinuation = nil
        lock.unlock()

        if let responseContinuation {
            responseContinuation.resume(throwing: error ?? LanguageModelTransportError(
                statusCode: 0, message: "connection closed before a response arrived"
            ))
        }
        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: body)
            }
        }
    }
}
#endif

#if AsyncHTTPClient
import AsyncHTTPClient
import NIOCore

extension XAIHTTPClient {
    static func postViaAsyncHTTPClient(_ request: URLRequest) async throws -> XAIResponsesBody {
        guard let url = request.url else {
            throw LanguageModelTransportError(statusCode: 0, message: "request has no URL")
        }
        var httpRequest = HTTPClientRequest(url: url.absoluteString)
        httpRequest.method = .RAW(value: request.httpMethod ?? "POST")
        for (header, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.headers.add(name: header, value: value)
        }
        if let body = request.httpBody {
            httpRequest.body = .bytes(ByteBuffer(bytes: body))
        }
        let timeout = TimeAmount.milliseconds(Int64((request.timeoutInterval * 1000).rounded()))
        let response = try await HTTPClient.shared.execute(httpRequest, timeout: timeout)
        var data = Data()
        for try await chunk in response.body {
            data.append(contentsOf: chunk.readableBytesView)
        }
        return XAIResponsesBody(
            data: data,
            statusCode: Int(response.status.code),
            headers: Dictionary(response.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
#endif

// MARK: - Input item builders

enum XAIInputBuilder {
    static func userMessage(text: String) -> JSONNode {
        .object([
            .init(key: "type", value: .string("message")),
            .init(key: "role", value: .string("user")),
            .init(key: "content", value: .array([
                .object([
                    .init(key: "type", value: .string("input_text")),
                    .init(key: "text", value: .string(text)),
                ]),
            ])),
        ])
    }

    static func functionCallOutput(callId: String, output: String) -> JSONNode {
        .object([
            .init(key: "type", value: .string("function_call_output")),
            .init(key: "call_id", value: .string(callId)),
            .init(key: "output", value: .string(output)),
        ])
    }

    static func entries(from transcript: Transcript, range: Range<Int>? = nil) -> [JSONNode] {
        let entries = Array(transcript.allEntries)
        let slice: ArraySlice<Transcript.Entry>
        if let range {
            slice = entries[range]
        } else {
            slice = entries[entries.startIndex...]
        }
        var items: [JSONNode] = []
        for entry in slice {
            items.append(contentsOf: inputItems(from: entry))
        }
        return items
    }

    static func instructionsText(from transcript: Transcript) -> String? {
        var parts: [String] = []
        for entry in transcript {
            if case .instructions(let instructions) = entry {
                let text = instructions.segments.joinedText
                if !text.isEmpty { parts.append(text) }
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func latestUserPrompt(from transcript: Transcript) -> String? {
        for entry in transcript.reversed() {
            if case .prompt(let prompt) = entry {
                let text = prompt.segments.joinedText
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func inputItems(from entry: Transcript.Entry) -> [JSONNode] {
        switch entry {
        case .instructions:
            return []
        case .prompt(let prompt):
            let text = prompt.segments.joinedText
            guard !text.isEmpty else { return [] }
            return [userMessage(text: text)]
        case .toolOutput(let output):
            let text = output.segments.joinedText
            return [functionCallOutput(callId: output.id, output: text)]
        case .toolCalls, .response, .reasoning:
            return []
        }
    }

    static func buildInlineInput(
        chain: [XAIConversationState.StoredTurn],
        newUserPrompt: String
    ) throws -> Data {
        var inputItems: [[String: Any]] = []
        for ancestor in chain {
            inputItems.append([
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": ancestor.prompt]],
            ])
            if let raw = ancestor.rawOutput,
                let priorItems = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] {
                for item in priorItems {
                    let type = item["type"] as? String ?? ""
                    if type == "reasoning" && item["encrypted_content"] == nil { continue }
                    var sanitized = item
                    if type == "message" {
                        let content = sanitized["content"] as? [[String: Any]] ?? []
                        if content.isEmpty {
                            sanitized["content"] = [["type": "output_text", "text": " "]]
                        }
                    }
                    inputItems.append(sanitized)
                }
            } else {
                let text = ancestor.outputText.isEmpty ? " " : ancestor.outputText
                inputItems.append([
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": text]],
                ])
            }
        }
        inputItems.append([
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": newUserPrompt]],
        ])
        return try JSONSerialization.data(withJSONObject: inputItems)
    }
}

func anyToJSONNode(_ value: Any) -> JSONNode {
    switch value {
    case is NSNull:
        return .null
    case let b as Bool:
        return .bool(b)
    case let n as NSNumber:
        let type = String(cString: n.objCType)
        if type == "c" || type == "B" { return .bool(n.boolValue) }
        if type == "f" || type == "d" { return .number(n.doubleValue) }
        return .integer(Int(n.int64Value))
    case let i as Int:
        return .integer(i)
    case let d as Double:
        return .number(d)
    case let s as String:
        return .string(s)
    case let arr as [Any]:
        return .array(arr.map(anyToJSONNode))
    case let dict as [String: Any]:
        return .object(dict.keys.sorted().map { key in
            JSONNode.Member(key: key, value: anyToJSONNode(dict[key]!))
        })
    default:
        return .string(String(describing: value))
    }
}

func extractRawOutputField(from body: Data) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let outputArray = obj["output"] as? [Any]
    else { return nil }
    return try? JSONSerialization.data(withJSONObject: outputArray)
}