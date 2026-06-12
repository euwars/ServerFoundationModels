// Apple-side model provider: the local on-device Apple model.
// This target intentionally does NOT depend on ServerFoundationModels, so the
// shared scenario file resolves `import FoundationModels`.

#if canImport(FoundationModels)
import FoundationModels

enum ParityModel {
    static let displayName = "Apple on-device (SystemLanguageModel)"

    static func make() -> SystemLanguageModel {
        .default
    }

    static let isOnDeviceBacked = true

    static let isAvailable: Bool = {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }()
}
#endif
