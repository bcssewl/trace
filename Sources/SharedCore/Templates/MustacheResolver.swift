import Foundation
import os

public enum MustacheResolver {
    private static let logger = Logger(subsystem: "app.trace", category: "templates.mustache")

    private static let recognizedTokens: Set<String> = [
        "transcript", "scratchpad", "calendar",
        "prior_notes", "project_vocab", "conversation_state",
    ]

    public static func resolve(template: String, context: RenderContext) -> String {
        var out = template
        let mappings: [(token: String, value: String)] = [
            ("transcript", context.transcript),
            ("scratchpad", context.scratchpad),
            ("calendar", AntiInjectionGuard.wrap(context.calendarUntrusted, source: .calendar)),
            ("prior_notes", AntiInjectionGuard.wrap(context.priorNotesUntrusted, source: .priorNotes)),
            ("project_vocab", context.projectVocab),
            ("conversation_state", context.conversationState),
        ]
        for (token, value) in mappings {
            out = out.replacingOccurrences(of: "{{\(token)}}", with: value)
        }
        warnOnUnknownTokens(in: out)
        return out
    }

    private static func warnOnUnknownTokens(in rendered: String) {
        let pattern = "\\{\\{\\s*([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(rendered.startIndex..., in: rendered)
        regex.enumerateMatches(in: rendered, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                let nameRange = Range(match.range(at: 1), in: rendered)
            else { return }
            let token = String(rendered[nameRange])
            if !recognizedTokens.contains(token) {
                logger.warning("MustacheResolver: unknown placeholder {{\(token, privacy: .public)}} left in output")
            }
        }
    }
}
