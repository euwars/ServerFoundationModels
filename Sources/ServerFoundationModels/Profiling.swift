// os_signpost emission for the Foundation Models Instrument (Xcode 27).
//
// Every model request and tool run is emitted as an os_signpost interval, so
// Instruments renders a Foundation Models events timeline — request latency,
// time-to-first-token, and tool spans — alongside the rest of a trace. The
// custom Instruments package in `Instruments/ServerFoundationModels.instrpkg`
// matches on the subsystem and categories below.
//
// Emission compiles to nothing where `os` is unavailable (Linux, and any
// non-Apple platform), so call sites stay free of platform guards beyond the
// thin `#if canImport(os)` blocks that wrap the interpolated messages.

#if canImport(os)
import os
#endif

/// Namespaced os_signpost logs for the profiling instrument.
///
/// The `subsystem` string is the contract with the Instruments package: change
/// it here and in `ServerFoundationModels.instrpkg` together. Adopters who want
/// their own spans to line up on the same timeline can emit under this same
/// subsystem.
public enum FMSignpost {
    /// The subsystem every ServerFoundationModels signpost is emitted under.
    public static let subsystem = "com.serverfoundationmodels"

    #if canImport(os)
    /// One interval per model HTTP request (start → stream fully consumed),
    /// carrying the model, session label, token counts, and time-to-first-token.
    package static let request = OSSignposter(subsystem: subsystem, category: "ModelRequest")

    /// One interval per tool execution inside (or around) a session's tool loop.
    package static let tool = OSSignposter(subsystem: subsystem, category: "ToolRun")
    #endif
}

extension Duration {
    /// Whole milliseconds, for signpost/timeline metadata. Clamps rather than
    /// overflowing on absurd inputs (durations here are request latencies).
    package var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        let millis = (seconds &* 1000) &+ (attoseconds / 1_000_000_000_000_000)
        return Int(clamping: millis)
    }
}
