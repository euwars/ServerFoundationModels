// ServerFoundationModels-side model provider.
//
// Both parity targets drive the SAME local on-device Apple model: the oracle
// through Apple's framework directly, this target through
// ServerFoundationModels's SystemLanguageModel bridge. Same model, same
// scenarios — every behavioral difference is attributable to the library.
//
// Provider packages (e.g. euwars/OpenrouterForFoundationModels, built with its
// ServerFoundationModels trait) validate the library against network-backed
// models — including on Linux, where the on-device model does not exist. See
// integration/openrouter-parity.

import Foundation
import ServerFoundationModels

enum ParityModel {
    static let displayName = "Apple on-device via ServerFoundationModels.SystemLanguageModel"

    static let isOnDeviceBacked = true

    static func make() -> SystemLanguageModel {
        .default
    }

    static let isAvailable: Bool = SystemLanguageModel.default.isAvailable
}
