// Credential modes for xAI. Production apps should route through a backend
// proxy (`.proxied`) rather than embedding API keys in client binaries.

import Foundation

public enum XAIAuthMode: Hashable, Sendable {
    case apiKey(String)
    case proxied(headers: [String: String])
}