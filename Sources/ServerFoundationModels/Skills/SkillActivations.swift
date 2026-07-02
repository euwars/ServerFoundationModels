// Skill activation state — the backing store for `Skills`. Ported from
// apple/foundation-models-utilities, adapted to ServerFoundationModels.

import Foundation
import Synchronization

/// A collection of active skill identifiers that tracks which skills have been
/// activated during a language model session.
///
/// Create an instance and pass it to ``Skills`` to provide the backing storage
/// for skill activation state. Iteration and ``snapshot()`` copy the active
/// names under a single lock acquisition; concurrent mutations do not affect an
/// iteration already in progress.
///
/// @unchecked Sendable invariant: `names` is guarded by `Mutex`.
public final class SkillActivations: @unchecked Sendable {
    private let names = Mutex([String]())

    public init() {}

    public func activate(_ name: String) {
        names.withLock {
            guard !$0.contains(name) else { return }
            $0.append(name)
        }
    }

    public func deactivate(_ name: String) {
        names.withLock { $0.removeAll { $0 == name } }
    }

    public func contains(_ name: String) -> Bool {
        names.withLock { $0.contains(name) }
    }

    /// Returns a copy of the active skill names under a single lock acquisition.
    public func snapshot() -> [String] {
        names.withLock { $0 }
    }
}

extension SkillActivations: Sequence {
    public func makeIterator() -> Array<String>.Iterator {
        snapshot().makeIterator()
    }
}