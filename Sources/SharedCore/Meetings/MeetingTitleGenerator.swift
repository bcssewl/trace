import Foundation

/// Turns a meeting transcript into a short, descriptive title via the
/// `.titleGeneration` task class (BAS-29), replacing the date-based fallback
/// ("Meeting 2026-05-29 16:12").
///
/// The model call goes through the
/// `ModelRoutingFacade` seam (so it's user-routable + testable with a scripted
/// router); the transcript is anti-injection wrapped before it reaches the model.
public struct MeetingTitleGenerator: Sendable {

    public static let maxTitleLength = 72

    private let router: any ModelRoutingFacade

    public init(router: any ModelRoutingFacade) {
        self.router = router
    }

    /// Generate a title from `transcript`, or `nil` when there's too little to
    /// title or the model yields nothing usable (the caller keeps the date
    /// fallback). `routeOverride` is normally nil — the router resolves
    /// `.titleGeneration` to the user's configured provider/model.
    public func generate(transcript: String, routeOverride: LLMRoute? = nil) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too little was said to title meaningfully — keep the date fallback.
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count >= 6 else { return nil }

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: Self.systemPrompt),
                LLMMessage(role: .user, content: AntiInjectionGuard.wrap(Self.clip(trimmed), source: .transcript)),
            ],
            taskClass: .titleGeneration,
            temperature: 0.3,
            maxTokens: 24
        )

        var text = ""
        do {
            for try await delta in router.stream(request, routeOverride: routeOverride) {
                text += delta.textIncrement
            }
        } catch {
            return nil
        }
        return Self.sanitize(text)
    }

    static let systemPrompt = """
        You write a concise, specific meeting title of 3–6 words capturing the main \
        topic. Output only the title — no quotes, no surrounding punctuation, and no \
        "Title:" prefix.
        """

    /// The opening of the transcript is enough to title from, and keeps a local
    /// model's call cheap.
    static func clip(_ transcript: String) -> String {
        String(transcript.prefix(2000))
    }

    /// Whether `title` is the date-based placeholder (or empty/nil) and should be
    /// replaced by a generated one — used to gate finalize + the backfill pass.
    public static func isPlaceholderTitle(_ title: String?) -> Bool {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return title.range(
            of: #"^Meeting \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression
        ) != nil
    }

    /// Clean a raw model reply into a single-line title: first line only, leading
    /// "Title:" label removed, surrounding quotes/asterisks/whitespace and trailing
    /// sentence punctuation peeled, internal whitespace collapsed, capped at a word
    /// boundary. `nil` when nothing usable remains.
    static func sanitize(_ raw: String) -> String? {
        var s = String(raw.prefix(while: { $0 != "\n" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = s.lowercased()
        for label in ["meeting title:", "title:"] where lower.hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        let junk = CharacterSet(charactersIn: "\"'“”‘’`* \t")
        let trailingPunct = CharacterSet(charactersIn: ".,;:")
        var changed = true
        while changed {
            let before = s
            s = s.trimmingCharacters(in: junk)
            while let last = s.unicodeScalars.last, trailingPunct.contains(last) {
                s.unicodeScalars.removeLast()
            }
            changed = s != before
        }

        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !s.isEmpty else { return nil }

        if s.count > maxTitleLength {
            var capped = ""
            for word in s.split(separator: " ") {
                let candidate = capped.isEmpty ? String(word) : capped + " " + word
                if candidate.count > maxTitleLength { break }
                capped = candidate
            }
            s = capped
        }
        return s.isEmpty ? nil : s
    }
}
