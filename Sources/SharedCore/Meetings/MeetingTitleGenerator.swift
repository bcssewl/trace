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
                LLMMessage(role: .user, content: AntiInjectionGuard.wrap(Self.sample(trimmed), source: .transcript)),
            ],
            taskClass: .titleGeneration,
            temperature: 0.3,
            maxTokens: 32
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
        Give the meeting a clear, specific title — the kind a person writes so they \
        recognise it later in a list. Capture what it was actually about: the main \
        subject plus the defining topics, goals, decisions, or outcomes that gave it \
        substance. Be specific and descriptive — a real title, not a vague category \
        ("French lesson: past-tense practice and café role-play", not just "French \
        lesson"). For example: "Q3 budget planning and headcount decisions", \
        "Mobile app onboarding redesign review", "Go-to-market plan for the new pricing \
        tier", "Pitch deck finalisation and investor follow-ups". Draw on the WHOLE \
        conversation; ignore incidental small-talk, greetings, and tangents that were \
        not the point. One line, roughly 4–10 words, no trailing punctuation. The \
        transcript may be in any language or mix languages; write the title in English. \
        Output only the title — no quotes and no "Title:" prefix.
        """

    /// How much transcript the title model reads. Generous enough to cover a whole
    /// meeting's worth of context while keeping the (possibly local) call bounded.
    static let maxTranscriptChars = 16_000

    /// The transcript the title model sees: the WHOLE transcript when it fits the
    /// budget, otherwise a representative sample spanning the entire call — head,
    /// evenly-spaced interior windows, and tail.
    ///
    /// Crucially this is NOT just the opening: a meeting's purpose (a lesson, a
    /// review, a decision) usually lives in the body, while the opening is warm-up
    /// small-talk. Titling from the opening alone is what produced "weekend chat"
    /// titles for a class; sampling the whole span fixes that.
    static func sample(_ transcript: String) -> String {
        let chars = Array(transcript)
        let total = chars.count
        if total <= maxTranscriptChars { return transcript }
        let windows = 8
        let windowLen = maxTranscriptChars / windows
        var pieces: [String] = []
        for i in 0..<windows {
            // Spread window starts evenly from the head (i=0) to the tail
            // (i=windows-1), so beginning, middle, and end are all represented.
            let start = (total - windowLen) * i / (windows - 1)
            let end = min(start + windowLen, total)
            pieces.append(String(chars[start..<end]))
        }
        return pieces.joined(separator: "\n…\n")
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
