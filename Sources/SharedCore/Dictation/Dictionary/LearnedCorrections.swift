import Foundation

/// Diff-based learning helper.
///
/// Compares the original raw ASR text to the user's manually edited final
/// text and proposes vocab corrections. The algorithm is deliberately
/// conservative: it only suggests single-word substitutions where one ASR
/// token maps to one corrected token. Multi-word edits are left to the user
/// to add as `ReplacementRule` entries directly.
public enum LearnedCorrections {
    /// A proposed correction extracted from an edit diff.
    public struct Suggestion: Sendable, Hashable, Codable {
        public let heard: String
        public let corrected: String
        public init(heard: String, corrected: String) {
            self.heard = heard
            self.corrected = corrected
        }
    }

    /// Extracts suggestions from a `(raw, edited)` pair.
    ///
    /// Tokenisation splits on whitespace. Punctuation is stripped from token
    /// edges before comparison so "Sarah." and "Sarah" compare equal. If the
    /// two strings have different token counts the function returns no
    /// suggestions — that case calls for a multi-word `ReplacementRule`, not a
    /// vocab entry.
    public static func suggestions(raw: String, edited: String) -> [Suggestion] {
        let rawTokens = tokenise(raw)
        let editedTokens = tokenise(edited)
        guard rawTokens.count == editedTokens.count, !rawTokens.isEmpty else {
            return []
        }
        var seen: Set<String> = []
        var out: [Suggestion] = []
        for (a, b) in zip(rawTokens, editedTokens) {
            if a.isEmpty || b.isEmpty { continue }
            if a.lowercased() == b.lowercased() && a != b {
                // Pure casing change — record it; the dictionary will
                // re-apply consistent casing next time the ASR mis-cases.
                let key = "\(a.lowercased())|\(b)"
                if seen.insert(key).inserted {
                    out.append(Suggestion(heard: a, corrected: b))
                }
                continue
            }
            if a.lowercased() != b.lowercased() {
                let key = "\(a.lowercased())|\(b)"
                if seen.insert(key).inserted {
                    out.append(Suggestion(heard: a, corrected: b))
                }
            }
        }
        return out
    }

    private static func tokenise(_ s: String) -> [String] {
        let trimChars = CharacterSet.punctuationCharacters
        return
            s
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: trimChars) }
    }
}
