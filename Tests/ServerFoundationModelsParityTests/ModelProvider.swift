// ServerFoundationModels-side model provider.
//
// Both parity targets currently drive the SAME local on-device Apple model:
// the oracle through Apple's framework directly, this target through
// ServerFoundationModels's SystemLanguageModel bridge. Same model, same scenarios —
// every behavioral difference is attributable to the library.
//
// Set PARITY_BACKEND=chat-completions to instead drive a local
// OpenAI-compatible server (PARITY_BASE_URL / PARITY_MODEL, defaulting to
// Ollama at localhost) — the configuration Linux CI uses, where the Apple
// on-device model does not exist.

import Foundation
import ServerFoundationModels
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
        : "Apple on-device via ServerFoundationModels.SystemLanguageModel"

    static func make() -> some LanguageModel {
        ChatCompletionsOrSystem(
            chat: ChatCompletionsLanguageModel(name: modelName, url: baseURL),
            useChat: useChatCompletions
        )
    }

    static let isAvailable: Bool = {
        if useChatCompletions {
            return chatCompletionsReachable(
                url: baseURL.appendingPathComponent("v1/models"),
                timeout: 2
            )
        }
        return SystemLanguageModel.default.isAvailable
    }()

    /// Synchronous reachability without blocking the Swift concurrency thread pool.
    /// The URLSession callback runs on a dedicated `Thread` that is joined before return.
    private static func chatCompletionsReachable(url: URL, timeout: TimeInterval) -> Bool {
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        let thread = Thread {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, response, _ in
                flag.value = (response as? HTTPURLResponse)?.statusCode == 200
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if flag.value {
                // print (not fputs+stderr): the C stderr global is not
                // concurrency-safe under Swift 6 on Linux.
                print("""

                ═══════════════════════════════════════════════════════════════════
                PARITY LIVE MODEL DETECTED — behavioral suites ACTIVATED
                Backend: ChatCompletionsLanguageModel
                URL: \(baseURL.absoluteString)  Model: \(modelName)
                To opt out: unset PARITY_BACKEND, or stop the server at \(baseURL.absoluteString)
                ═══════════════════════════════════════════════════════════════════

                """)
            }
        }
        thread.start()
        while !thread.isFinished {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return flag.value
    }
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
                let executor = SystemLanguageModel.Executor(configuration: .init())
                try await executor.respond(to: request, model: .default, streamingInto: channel)
            }
        }
    }
}