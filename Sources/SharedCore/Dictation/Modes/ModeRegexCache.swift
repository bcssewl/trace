import Foundation
import os

/// Process-wide cache of compiled `NSRegularExpression`s for mode matching.
///
/// Mode resolution runs on every hotkey press and previously recompiled every
/// mode's `bundleIDRegex` (and, in browsers, `urlRegex`) from scratch each
/// time. Patterns are tiny and few, but compilation is pure waste on a
/// latency-sensitive path — cache by (pattern, options) instead.
///
/// `NSRegularExpression` is immutable and thread-safe, so sharing compiled
/// instances across callers is sound. Bounded: the cache resets if it ever
/// exceeds `maxEntries` (only reachable by pathological churn of user
/// patterns).
public enum ModeRegexCache {
    private struct Key: Hashable {
        let pattern: String
        let options: NSRegularExpression.Options.RawValue
    }

    private static let maxEntries = 512
    private static let storage = OSAllocatedUnfairLock<[Key: NSRegularExpression]>(initialState: [:])

    /// Returns the cached compiled regex for `pattern`, compiling (and caching)
    /// on first use. Throws the compiler's error for an invalid pattern —
    /// invalid patterns are NOT cached, so a user fixing their mode takes
    /// effect immediately.
    public static func compiled(
        _ pattern: String, options: NSRegularExpression.Options = []
    ) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, options: options.rawValue)
        if let hit = storage.withLock({ $0[key] }) {
            return hit
        }
        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        storage.withLock { cache in
            if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
            cache[key] = compiled
        }
        return compiled
    }
}

/// One invalid user pattern discovered during mode resolution.
public struct ModePatternIssue: Sendable, Equatable, Identifiable {
    public enum Field: String, Sendable {
        case bundleIDRegex
        case urlRegex
    }

    public let modeID: UUID
    public let modeName: String
    public let field: Field
    public let pattern: String
    public let message: String

    public var id: String { "\(modeID.uuidString).\(field.rawValue)" }

    public init(modeID: UUID, modeName: String, field: Field, pattern: String, message: String) {
        self.modeID = modeID
        self.modeName = modeName
        self.field = field
        self.pattern = pattern
        self.message = message
    }
}

/// Loud, queryable record of invalid mode patterns.
///
/// A broken user regex must not break dictation (the resolver skips that mode)
/// but it must not be silent either: each issue is error-logged, kept here for
/// Settings to display next to the offending mode, and announced via
/// `ModeDiagnostics.issuesDidChange` so an open Settings pane can refresh.
public final class ModeDiagnostics: @unchecked Sendable {
    public static let shared = ModeDiagnostics()

    /// Posted (on no particular thread) whenever the issue set changes.
    public static let issuesDidChange = Notification.Name("app.trace.dictation.modePatternIssuesChanged")

    private let storage = OSAllocatedUnfairLock<[String: ModePatternIssue]>(initialState: [:])

    public init() {}

    /// Records (or refreshes) an issue. Logged loudly on first sighting.
    public func report(_ issue: ModePatternIssue) {
        let isNew = storage.withLock { issues -> Bool in
            let existed = issues[issue.id] != nil
            issues[issue.id] = issue
            return !existed
        }
        if isNew {
            Loggers.dictation.error(
                "Mode \"\(issue.modeName, privacy: .public)\" has an invalid \(issue.field.rawValue, privacy: .public) pattern (\(issue.pattern, privacy: .public)) — the mode is skipped during resolution until it is fixed: \(issue.message, privacy: .public)"
            )
            NotificationCenter.default.post(name: Self.issuesDidChange, object: nil)
        }
    }

    /// Clears any recorded issue for a mode's field — call when the pattern
    /// compiles again (the user fixed it).
    public func clear(modeID: UUID, field: ModePatternIssue.Field) {
        let removed = storage.withLock { issues in
            issues.removeValue(forKey: "\(modeID.uuidString).\(field.rawValue)") != nil
        }
        if removed {
            NotificationCenter.default.post(name: Self.issuesDidChange, object: nil)
        }
    }

    /// All currently-known invalid patterns (for Settings display).
    public func currentIssues() -> [ModePatternIssue] {
        storage.withLock { Array($0.values) }.sorted { $0.modeName < $1.modeName }
    }
}
