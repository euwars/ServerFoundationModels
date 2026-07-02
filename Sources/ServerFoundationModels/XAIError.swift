// xAI transport errors. Fail loud on non-2xx before decoding — response bodies
// have all-optional fields and would otherwise look like empty successes.

import Foundation

public struct XAIError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let body: String
    public let retryAfter: String?

    public init(status: Int, body: String, retryAfter: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }

    public var description: String {
        "xAI HTTP \(status): \(body.prefix(500))"
    }

    public static func isThreadingContentElementError(_ error: XAIError) -> Bool {
        error.status == 400
            && error.body.contains("Each message must have at least one content element")
    }
}

enum XAIErrorMapper {
    static func map(_ error: XAIError) -> any Error {
        let mapped = mapTransport(
            statusCode: error.status,
            body: error.body,
            retryAfter: error.retryAfter
        )
        if mapped is LanguageModelTransportError {
            return error
        }
        return mapped
    }

    static func mapTransport(statusCode: Int, body: String, retryAfter: String? = nil) -> any Error {
        if statusCode == 429 {
            let resetDate = retryAfter.flatMap { HTTPErrorHeuristics.retryAfterDate(fromHeaderValue: $0) }
            return LanguageModelError.rateLimited(.init(resetDate: resetDate, debugDescription: body))
        }
        if HTTPErrorHeuristics.isContextOverflow(statusCode: statusCode, body: body) {
            return LanguageModelError.contextSizeExceeded(.init(
                contextSize: 0, tokenCount: 0, debugDescription: body
            ))
        }
        return LanguageModelTransportError(statusCode: statusCode, message: body)
    }

    static func streamStatusCode(from event: JSONNode) -> Int {
        func intFrom(_ node: JSONNode?) -> Int? {
            if case .integer(let value) = node { return Int(value) }
            if case .number(let value) = node, let exact = Int(exactly: value) { return exact }
            if case .string(let value) = node, let code = Int(value) { return code }
            return nil
        }

        func stringCodeStatus(_ node: JSONNode?) -> Int {
            guard case .string(let code) = node else { return 0 }
            return knownStringCodeStatus(code)
        }

        func statusFromErrorObject(_ error: JSONNode) -> Int {
            if let code = intFrom(error["code"]) ?? intFrom(error["status"]) { return code }
            return stringCodeStatus(error["code"])
        }

        if let code = intFrom(event["status"]) { return code }
        if let code = intFrom(event["code"]) { return code }
        let topLevelStringCode = stringCodeStatus(event["code"])
        if topLevelStringCode != 0 { return topLevelStringCode }

        if let error = event["error"] {
            let code = statusFromErrorObject(error)
            if code != 0 { return code }
        }

        if let response = event["response"] {
            if let code = intFrom(response["status"]) { return code }
            if let error = response["error"] {
                let code = statusFromErrorObject(error)
                if code != 0 { return code }
            }
        }

        return 0
    }

    private static func knownStringCodeStatus(_ code: String) -> Int {
        switch code {
        case "rate_limit_exceeded", "rate_limit", "too_many_requests": return 429
        default: return 0
        }
    }
}
