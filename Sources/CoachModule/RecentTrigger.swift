import Foundation

/// One entry in the overlay's "Recent cues" log: a card the listener produced,
/// whether or not it actually surfaced.
///
/// `wasSurfaced == false` means the card was WITHHELD by a code gate (the
/// rolling card allowance or the minimum spacing between automatic cards) —
/// logged here so withholding is visible, never silent.
///
/// Lives in CoachModule (it moved from the AppShell overlay) so the LABEL
/// HYGIENE below is enforced at the data layer: callers feed LLM-derived titles
/// straight in, and the init guarantees the stored label is renderable no matter
/// what the model produced — empty, whitespace, control garbage, or a runaway
/// paragraph all clamp to something honest.
public struct RecentTrigger: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let label: String
    public let kind: CoachCardKind
    public let wasSurfaced: Bool
    /// The full card behind this log entry, kept so a cue can be REOPENED after
    /// it auto-hides — a card that pops for twelve seconds and then becomes
    /// unreachable reads as "I got a notification but there's nothing there".
    public let card: CoachCard?

    /// Maximum stored label length; anything longer is truncated with an ellipsis
    /// (the overlay renders one line anyway).
    static let maxLabelLength = 80

    public init(
        id: UUID = UUID(), timestamp: Date = Date(), label: String, kind: CoachCardKind,
        wasSurfaced: Bool, card: CoachCard? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.label = Self.sanitisedLabel(label, kind: kind)
        self.kind = kind
        self.wasSurfaced = wasSurfaced
        self.card = card
    }

    /// Clamp an LLM-derived title to a renderable one-line label:
    /// - collapse all whitespace (including newlines) to single spaces,
    /// - strip control characters,
    /// - fall back to a per-kind name when nothing substantive remains,
    /// - truncate overlong titles with an ellipsis.
    static func sanitisedLabel(_ raw: String, kind: CoachCardKind) -> String {
        let collapsed =
            raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let cleaned = String(
            String.UnicodeScalarView(
                collapsed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            )
        )
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else {
            return fallbackLabel(for: kind)
        }
        if cleaned.count > maxLabelLength {
            let cut = cleaned.prefix(maxLabelLength - 1)
            return cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }

    /// The honest stand-in label when a title is empty/garbled — names the cue by
    /// its kind instead of rendering garbage.
    static func fallbackLabel(for kind: CoachCardKind) -> String {
        switch kind {
        case .answer: return "Answer"
        case .recall: return "From your notes"
        case .suggestion: return "Suggestion"
        }
    }
}
