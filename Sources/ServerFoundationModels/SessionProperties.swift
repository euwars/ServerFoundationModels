// Session properties — typed, session-scoped values that tools and dynamic
// instructions can read and write. Mirrors FoundationModels (SDK 27):
// SessionPropertyKey, SessionPropertyValues, @SessionPropertyEntry, and the
// LanguageModelSession.SessionProperty wrapper.

import Foundation
import Logging

public protocol SessionPropertyKey: SendableMetatype {
    associatedtype Value
    static var defaultValue: Value { get }
}

public final class SessionPropertyValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<K>(key: K.Type) -> K.Value where K: SessionPropertyKey {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue
        }
        set {
            lock.lock()
            storage[ObjectIdentifier(key)] = newValue
            lock.unlock()
        }
    }

    /// The session-property context active for the current task — bound by
    /// the session around profile resolution and tool execution so
    /// `@SessionProperty` wrappers resolve against the right session.
    @TaskLocal static var current: SessionPropertyValues?

    /// Warns (once per process) about `@SessionProperty` access outside any
    /// session binding. Such reads return default values and writes are
    /// dropped — they must never share process-global mutable state, which
    /// would leak data across sessions on a server.
    static func warnAccessOutsideSession() {
        _ = warnAccessOutsideSessionOnce
    }

    private static let warnAccessOutsideSessionOnce: Void = {
        Logger(label: "ServerFoundationModels").warning(
            "@SessionProperty accessed outside a session context (e.g. from Task.detached): reads return default values and writes are dropped"
        )
    }()
}

// MARK: - Built-in entries

extension SessionPropertyValues {
    public struct __Key_history: SessionPropertyKey {
        public static var defaultValue: ArraySlice<Transcript.Entry> { [] }
    }

    /// The conversation history for the request being prepared.
    public var history: ArraySlice<Transcript.Entry> {
        get { self[__Key_history.self] }
        set { self[__Key_history.self] = newValue }
    }

    public struct __Key_rootDynamicInstructions: SessionPropertyKey {
        public static var defaultValue: any DynamicInstructions { EmptyDynamicInstructions() }
    }

    /// The top-level dynamic instructions for the session, when profile-based.
    public var rootDynamicInstructions: any DynamicInstructions {
        get { self[__Key_rootDynamicInstructions.self] }
        set { self[__Key_rootDynamicInstructions.self] = newValue }
    }
}

// MARK: - Property wrapper

extension LanguageModelSession {
    @propertyWrapper
    public struct SessionProperty<Value> {
        let keyPath: ReferenceWritableKeyPath<SessionPropertyValues, Value>

        public init(_ keyPath: ReferenceWritableKeyPath<SessionPropertyValues, Value>) {
            self.keyPath = keyPath
        }

        public var wrappedValue: Value {
            get {
                guard let current = SessionPropertyValues.current else {
                    // Outside any session binding: resolve against a fresh,
                    // empty store so the read yields the default value —
                    // never a process-global object shared across sessions.
                    SessionPropertyValues.warnAccessOutsideSession()
                    return SessionPropertyValues()[keyPath: keyPath]
                }
                return current[keyPath: keyPath]
            }
            nonmutating set {
                guard let current = SessionPropertyValues.current else {
                    // Outside any session binding the write is dropped: it
                    // has no session to belong to, and a global fallback
                    // would leak values across sessions.
                    SessionPropertyValues.warnAccessOutsideSession()
                    return
                }
                current[keyPath: keyPath] = newValue
            }
        }
    }
}

extension LanguageModelSession.SessionProperty: @unchecked Sendable where Value: Sendable {}

extension Tool {
    public typealias SessionProperty = LanguageModelSession.SessionProperty
}

extension DynamicInstructions {
    public typealias SessionProperty = LanguageModelSession.SessionProperty
}

extension LanguageModelSession.DynamicProfile {
    public typealias SessionProperty = LanguageModelSession.SessionProperty
}

extension LanguageModelSession.DynamicProfileModifier {
    public typealias SessionProperty = LanguageModelSession.SessionProperty
}
