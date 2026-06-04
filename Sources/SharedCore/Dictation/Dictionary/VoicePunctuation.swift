import Foundation

/// Spoken punctuation directives recognized by the personal dictionary before
/// the cleanup LLM runs.
///
/// Each case carries a list of trigger phrases. The dictionary matches them
/// case-insensitively at word boundaries and substitutes the literal `glyph`.
public enum VoicePunctuation: String, Sendable, Hashable, Codable, CaseIterable {
    case period
    case comma
    case questionMark
    case exclamationMark
    case colon
    case semicolon
    case ellipsis
    case dash
    case emDash
    case openQuote
    case closeQuote
    case openParen
    case closeParen
    case newLine
    case newParagraph
    case bulletPoint

    public var glyph: String {
        switch self {
        case .period: return "."
        case .comma: return ","
        case .questionMark: return "?"
        case .exclamationMark: return "!"
        case .colon: return ":"
        case .semicolon: return ";"
        case .ellipsis: return "..."
        case .dash: return "-"
        case .emDash: return "—"
        case .openQuote: return "\""
        case .closeQuote: return "\""
        case .openParen: return "("
        case .closeParen: return ")"
        case .newLine: return "\n"
        case .newParagraph: return "\n\n"
        case .bulletPoint: return "\n- "
        }
    }

    /// Phrases the ASR may transcribe that should map to this directive.
    public var triggers: [String] {
        switch self {
        case .period: return ["period", "full stop"]
        case .comma: return ["comma"]
        case .questionMark: return ["question mark"]
        case .exclamationMark: return ["exclamation mark", "exclamation point"]
        case .colon: return ["colon"]
        case .semicolon: return ["semicolon"]
        case .ellipsis: return ["ellipsis", "dot dot dot"]
        case .dash: return ["dash", "hyphen"]
        case .emDash: return ["em dash", "long dash"]
        case .openQuote: return ["open quote", "begin quote"]
        case .closeQuote: return ["close quote", "end quote"]
        case .openParen: return ["open paren", "open parenthesis"]
        case .closeParen: return ["close paren", "close parenthesis"]
        case .newLine: return ["new line"]
        case .newParagraph: return ["new paragraph"]
        case .bulletPoint: return ["bullet point", "new bullet"]
        }
    }
}
