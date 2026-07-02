// Skill activation state — the backing store for `Skills`. Ported from
// apple/foundation-models-utilities, adapted to ServerFoundationModels.

import Foundation

/// A collection of active skill identifiers that tracks which skills have been
/// activated during a language model session.
///
/// Create an instance and pass it to ``Skills`` to provide the backing storage
/// for skill activation state. Iteration and ``snapshot()`` copy the active
/// names under a single lock acquisition; concurrent mutations do not affect an
/// iteration already in progress.
public final class SkillActivations: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func activate(_ name: String) {
        withLock {
            guard !names.contains(name) else { return }
            names.append(name)
        }
    }

    public func deactivate(_ name: String) {
        withLock { names.removeAll { $0 == name } }
    }

    public func contains(_ name: String) -> Bool {
        withLock { names.contains(name) }
    }

    /// Returns a copy of the active skill names under a single lock acquisition.
    public func snapshot() -> [String] {
        withLock { names }
    }
}

extension SkillActivations: Sequence {
    public func makeIterator() -> Array<String>.Iterator {
        snapshot().makeIterator()
    }
}
