// Credential modes for xAI. Production apps should route through a backend
// proxy (`.proxied`) rather than embedding API keys in client binaries.

import Foundation

public enum XAIAuthMode: Hashable, Sendable {
    case apiKey(String)
    case proxied(headers: [String: String])
}

extension XAIAuthMode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { redactedDescription }
    public var debugDescription: String { redactedDescription }

    private var redactedDescription: String {
        switch self {
        case .apiKey:
            return "apiKey(<redacted>)"
        case .proxied(let headers):
            let names = headers.keys.sorted().joined(separator: ", ")
            return "proxied(\(names))"
        }
    }
}
