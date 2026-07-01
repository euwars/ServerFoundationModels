// Server-side tools that execute on xAI infrastructure (web search, X search).

import Foundation

public enum XAIServerTool: Hashable, Sendable {
    case webSearch
    case xSearch

    public var wireType: String {
        switch self {
        case .webSearch: "web_search"
        case .xSearch: "x_search"
        }
    }
}