// Skill activation state — the backing store for `Skills`. Ported from
// apple/foundation-models-utilities, adapted to ServerFoundationModels.

import Foundation
import Synchronization

/// A collection of active skill identifiers that tracks which skills have been
/// activated during a language model session.
///
/// Create an instance and pass it to ``Skills`` to provide the backing storage
/// for skill activation state. It is safe to read from any thread.
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
}

extension SkillActivations: RandomAccessCollection {
    public var startIndex: Int { names.withLock { $0.startIndex } }
    public var endIndex: Int { names.withLock { $0.endIndex } }
    public subscript(position: Int) -> String { names.withLock { $0[position] } }
}