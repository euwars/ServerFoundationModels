// xAI transport errors. Fail loud on non-2xx before decoding — response bodies
// have all-optional fields and would otherwise look like empty successes.

import Foundation

public struct XAIError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
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
        if error.status == 429 {
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: error.body))
        }
        let lowered = error.body.lowercased()
        if [400, 413].contains(error.status),
            lowered.contains("context") || lowered.contains("maximum length"),
            lowered.contains("token") || lowered.contains("length") || lowered.contains("window") {
            return LanguageModelError.contextSizeExceeded(.init(
                contextSize: 0, tokenCount: 0, debugDescription: error.body
            ))
        }
        return error
    }

    static func mapTransport(statusCode: Int, body: String) -> any Error {
        if statusCode == 429 {
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: body))
        }
        return LanguageModelTransportError(statusCode: statusCode, message: body)
    }
}