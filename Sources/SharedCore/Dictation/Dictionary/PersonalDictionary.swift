import Foundation

/// The user's personal dictionary applied to raw ASR text before LLM cleanup.
///
/// Pipeline order (per spec §5.1):
/// 1. Voice-punctuation directives ("period", "new line", "em dash", …)
///    substitute their glyphs.
/// 2. Replacement rules (regex find/replace) fire next.
/// 3. Vocabulary corrections — case-insensitive whole-word substitutions —
///    fire last so they win over upstream phrases that may have been
///    rewritten by the earlier steps.
///
/// Vocab entries are loaded from the `vocab_corrections` SQLite table when a
/// database is supplied. The dictionary keeps replacement rules and voice
/// punctuation in memory; persistence for those is owned by the settings layer
/// (out of scope for M08).
public actor PersonalDictionary {
    private let database: SqliteDatabase?
    private var vocab: [VocabEntry] = []
    private var replacements: [ReplacementRule] = []
    private let voiceCommands: [VoicePunctuation]
    private var bootstrapped = false

    public init(database: SqliteDatabase? = nil, voiceCommands: [VoicePunctuation] = VoicePunctuation.allCases) {
        self.database = database
        self.voiceCommands = voiceCommands
    }

    /// Loads persisted vocab corrections.
    ///
    /// Idempotent.
    public func bootstrap() async throws {
        guard !bootstrapped else { return }
        if let database {
            try await loadVocab(from: database)
        }
        bootstrapped = true
        Loggers.dictation.info("PersonalDictionary bootstrapped (\(self.vocab.count, privacy: .public) vocab)")
    }

    public func vocabEntries() -> [VocabEntry] {
        vocab
    }

    public func replacementRules() -> [ReplacementRule] {
        replacements
    }

    public func setReplacementRules(_ rules: [ReplacementRule]) {
        replacements = rules
    }

    /// Records a new vocab correction.
    ///
    /// Increments `hitCount` if `heard` is
    /// already present with the same `corrected` value.
    public func recordCorrection(heard: String, corrected: String, at timestamp: TimeInterval) async throws {
        guard !heard.isEmpty, !corrected.isEmpty else { return }
        if let index = vocab.firstIndex(where: {
            $0.heard.caseInsensitiveCompare(heard) == .orderedSame
                && $0.corrected == corrected
        }) {
            vocab[index].hitCount += 1
        } else {
            vocab.append(
                VocabEntry(
                    heard: heard,
                    corrected: corrected,
                    learnedAt: timestamp,
                    hitCount: 1
                )
            )
        }
        if let database {
            try await persistCorrection(heard: heard, corrected: corrected, at: timestamp, into: database)
        }
    }

    /// Applies the dictionary pipeline to a raw ASR string.
    ///
    /// Returns the rewritten text plus the count of substitutions made (used
    /// by callers that want to surface "5 dictionary fixes" UI hints).
    public func apply(_ raw: String) throws -> (text: String, substitutions: Int) {
        var current = raw
        var count = 0

        // Voice punctuation first — these must fire before regex rules so
        // user-written rules can target the resulting glyphs. Sort triggers
        // by descending word count so multi-word phrases (e.g. "em dash")
        // match before their single-word substrings ("dash").
        struct Trigger {
            let phrase: String
            let glyph: String
            let length: Int
        }
        var triggers: [Trigger] = []
        for directive in voiceCommands {
            for phrase in directive.triggers {
                triggers.append(Trigger(phrase: phrase, glyph: directive.glyph, length: phrase.count))
            }
        }
        triggers.sort { $0.length > $1.length }
        for trigger in triggers {
            let (next, hits) = replaceWordBoundary(in: current, phrase: trigger.phrase, with: trigger.glyph)
            current = next
            count += hits
        }

        // Replacement rules — user-authored regexes.
        for rule in replacements {
            let regex = try rule.compiled()
            let range = NSRange(current.startIndex..., in: current)
            let beforeCount = current.count
            current = regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
            if current.count != beforeCount {
                count += 1
            }
        }

        // Vocab corrections — whole-word, case-insensitive.
        for entry in vocab {
            let (next, hits) = replaceWordBoundary(in: current, phrase: entry.heard, with: entry.corrected)
            current = next
            count += hits
        }

        return (current, count)
    }

    /// Whole-word case-insensitive replacement that preserves the surrounding
    /// whitespace.
    ///
    /// Returns the new string and the number of replacements made.
    private func replaceWordBoundary(in source: String, phrase: String, with replacement: String) -> (String, Int) {
        guard !phrase.isEmpty else { return (source, 0) }
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        // \b doesn't fire at apostrophes or hyphens reliably for multi-word
        // triggers, so anchor with (?<!\\S) ... (?!\\S) — start of token /
        // end of token. This handles "period" at end of sentence as well as
        // "open quote" at start of sentence.
        let pattern = "(?<!\\S)\(escaped)(?!\\S)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (source, 0)
        }
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: range)
        if matches.isEmpty { return (source, 0) }
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        let rewritten = regex.stringByReplacingMatches(
            in: source,
            options: [],
            range: range,
            withTemplate: escapedReplacement
        )
        return (rewritten, matches.count)
    }

    private func loadVocab(from db: SqliteDatabase) async throws {
        let entries = try await db.withStatement(
            sql: "SELECT heard, corrected, updated_at, count FROM vocab_corrections ORDER BY updated_at DESC"
        ) { stmt -> [VocabEntry] in
            var out: [VocabEntry] = []
            while case .row = try stmt.step() {
                let heard = stmt.columnText(at: 0) ?? ""
                let corrected = stmt.columnText(at: 1) ?? ""
                let updatedAt = stmt.columnInt64(at: 2)
                let count = stmt.columnInt(at: 3)
                if !heard.isEmpty, !corrected.isEmpty {
                    out.append(
                        VocabEntry(
                            heard: heard,
                            corrected: corrected,
                            learnedAt: TimeInterval(updatedAt),
                            hitCount: count
                        )
                    )
                }
            }
            return out
        }
        vocab = entries
    }

    private func persistCorrection(
        heard: String,
        corrected: String,
        at timestamp: TimeInterval,
        into db: SqliteDatabase
    ) async throws {
        try await db.withStatement(
            sql: """
                INSERT INTO vocab_corrections (heard, corrected, count, updated_at)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(heard, corrected) DO UPDATE SET count = count + 1, updated_at = excluded.updated_at
                """
        ) { stmt in
            try stmt.bind(text: heard, at: 1)
            try stmt.bind(text: corrected, at: 2)
            try stmt.bind(int64: Int64(timestamp), at: 3)
            _ = try stmt.step()
        }
    }
}
