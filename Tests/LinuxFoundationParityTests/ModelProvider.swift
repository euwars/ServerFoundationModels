// LinuxFoundation-side model provider: a local open model served by
// Ollama (or any OpenAI-compatible server), driven through this package's
// ChatCompletionsLanguageModel.
//
// Override with PARITY_BASE_URL / PARITY_MODEL environment variables.

import Foundation
import LinuxFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ParityModel {
    static let baseURL = URL(
        string: ProcessInfo.processInfo.environment["PARITY_BASE_URL"] ?? "http://localhost:11434"
    )!
    static let modelName = ProcessInfo.processInfo.environment["PARITY_MODEL"] ?? "qwen3.5:9b"

    static let displayName = "\(modelName) via \(baseURL.absoluteString) (ChatCompletionsLanguageModel)"

    static func make() -> ChatCompletionsLanguageModel {
        ChatCompletionsLanguageModel(name: modelName, url: baseURL)
    }

    static let isAvailable: Bool = {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 2

        var available = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            available = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return available
    }()
}
