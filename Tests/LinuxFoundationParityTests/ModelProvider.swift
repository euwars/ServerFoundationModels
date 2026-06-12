// LinuxFoundation-side model provider.
//
// Both parity targets currently drive the SAME local on-device Apple model:
// the oracle through Apple's framework directly, this target through
// LinuxFoundation's SystemLanguageModel bridge. Same model, same scenarios —
// every behavioral difference is attributable to the library.
//
// Set PARITY_BACKEND=chat-completions to instead drive a local
// OpenAI-compatible server (PARITY_BASE_URL / PARITY_MODEL, defaulting to
// Ollama at localhost) — the configuration Linux CI uses, where the Apple
// on-device model does not exist.

import Foundation
import LinuxFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ParityModel {
    static let useChatCompletions =
        ProcessInfo.processInfo.environment["PARITY_BACKEND"] == "chat-completions"

    static let baseURL = URL(
        string: ProcessInfo.processInfo.environment["PARITY_BASE_URL"] ?? "http://localhost:11434"
    )!
    static let modelName = ProcessInfo.processInfo.environment["PARITY_MODEL"] ?? "qwen3.5:9b"

    static let isOnDeviceBacked = !useChatCompletions

    static let displayName = useChatCompletions
        ? "\(modelName) via \(baseURL.absoluteString) (ChatCompletionsLanguageModel)"
        : "Apple on-device via LinuxFoundation.SystemLanguageModel"

    static func make() -> some LanguageModel {
        ChatCompletionsOrSystem(
            chat: ChatCompletionsLanguageModel(name: modelName, url: baseURL),
            useChat: useChatCompletions
        )
    }

    static let isAvailable: Bool = {
        if useChatCompletions {
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
        }
        return SystemLanguageModel.default.isAvailable
    }()
}

/// Selects the backend at runtime while presenting a single concrete
/// LanguageModel type to the shared scenarios.
struct ChatCompletionsOrSystem: LanguageModel {
    var chat: ChatCompletionsLanguageModel
    var useChat: Bool

    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities(capabilities: [.toolCalling, .guidedGeneration]) }

    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(
            chat: useChat ? chat.executorConfiguration : nil
        )
    }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable {
            var chat: ChatCompletionsLanguageModel.Executor.Configuration?
        }

        let configuration: Configuration

        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ChatCompletionsOrSystem,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            if let chatConfiguration = configuration.chat {
                let executor = try ChatCompletionsLanguageModel.Executor(configuration: chatConfiguration)
                try await executor.respond(to: request, model: model.chat, streamingInto: channel)
            } else {
                let executor = try SystemLanguageModel.Executor(configuration: .init())
                try await executor.respond(to: request, model: .default, streamingInto: channel)
            }
        }
    }
}
