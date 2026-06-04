import Foundation

/// One entry in the personal dictation dictionary.
///
/// Three flavors:
/// - `.vocab(_:)` — a literal vocabulary term the ASR keeps mis-hearing
///   (e.g. `optivise` -> `Optivise`). Applied as a whole-word case-insensitive
///   replacement that preserves casing intent when the replacement carries
///   mixed-case characters.
/// - `.replacement(_:)` — an arbitrary regex-driven find/replace rule applied
///   verbatim. Used for stylistic transforms like "double dash" -> "—".
/// - `.voicePunctuation(_:)` — a `VoicePunctuation` directive (period, comma,
///   newline, etc.). Listed here so the rule sets compose in a single
///   pipeline. Voice-punctuation entries are populated from `VoicePunctuation`
///   and not stored in user-data.
public enum DictionaryEntry: Sendable, Hashable, Codable {
    case vocab(VocabEntry)
    case replacement(ReplacementRule)
    case voicePunctuation(VoicePunctuation)

    /// Pre-LLM apply priority.
    ///
    /// Voice punctuation runs first (it has to fire
    /// before the cleanup LLM sees the text), then replacement rules, then
    /// vocab corrections.
    public var priority: Int {
        switch self {
        case .voicePunctuation: return 0
        case .replacement: return 1
        case .vocab: return 2
        }
    }
}

/// A single mis-heard-word correction.
///
/// `heard` is matched case-insensitively as a whole word boundary; `corrected`
/// is the exact replacement string.
public struct VocabEntry: Sendable, Hashable, Codable {
    public let heard: String
    public let corrected: String
    public let learnedAt: TimeInterval
    /// Hit count — incremented every time the rule fires.
    ///
    /// Lets the UI surface
    /// the rules the user gets the most value from.
    public var hitCount: Int

    public init(heard: String, corrected: String, learnedAt: TimeInterval, hitCount: Int = 0) {
        self.heard = heard
        self.corrected = corrected
        self.learnedAt = learnedAt
        self.hitCount = hitCount
    }
}

/// A regex-driven find/replace rule.
public struct ReplacementRule: Sendable, Hashable, Codable {
    public let pattern: String
    public let replacement: String
    public let caseInsensitive: Bool
    public let createdAt: TimeInterval

    public init(pattern: String, replacement: String, caseInsensitive: Bool = true, createdAt: TimeInterval) {
        self.pattern = pattern
        self.replacement = replacement
        self.caseInsensitive = caseInsensitive
        self.createdAt = createdAt
    }

    /// Compiles the regex eagerly so callers see a config error at edit time.
    public func compiled() throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw TraceError.configInvalid(
                field: "ReplacementRule.pattern",
                reason: "Pattern \(pattern) failed to compile: \(error.localizedDescription)"
            )
        }
    }
}
