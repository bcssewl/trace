import Foundation

/// One entry in the overlay's "Recent cues" log: a moment the coach detected,
/// whether or not a card actually surfaced for it.
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
    public let mode: CoachCardMode
    public let wasSurfaced: Bool

    /// Maximum stored label length; anything longer is truncated with an ellipsis
    /// (the overlay renders one line anyway).
    static let maxLabelLength = 80

    public init(id: UUID = UUID(), timestamp: Date = Date(), label: String, mode: CoachCardMode, wasSurfaced: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.label = Self.sanitisedLabel(label, mode: mode)
        self.mode = mode
        self.wasSurfaced = wasSurfaced
    }

    /// Clamp an LLM-derived title to a renderable one-line label:
    /// - collapse all whitespace (including newlines) to single spaces,
    /// - strip control characters,
    /// - fall back to a per-mode name when nothing substantive remains,
    /// - truncate overlong titles with an ellipsis.
    static func sanitisedLabel(_ raw: String, mode: CoachCardMode) -> String {
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
            return fallbackLabel(for: mode)
        }
        if cleaned.count > maxLabelLength {
            let cut = cleaned.prefix(maxLabelLength - 1)
            return cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }

    /// The honest stand-in label when a title is empty/garbled — names the cue by
    /// its classification instead of rendering garbage. British English
    /// ("synthesised").
    static func fallbackLabel(for mode: CoachCardMode) -> String {
        switch mode {
        case .grounded: return "Grounded cue"
        case .synthesized: return "Synthesised cue"
        case .general: return "General cue"
        case .reframe: return "Reframe cue"
        case .agenda: return "Agenda cue"
        case .silent: return "Cue"
        }
    }
}
