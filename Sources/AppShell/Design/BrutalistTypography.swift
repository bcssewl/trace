import SwiftUI

/// App type scale.
///
/// Design intent (revised): the UI **chrome** — page titles, group headers,
/// row labels, descriptions, buttons — uses the **system font (SF Pro)** in
/// sentence case, so the app reads like a friendly native Mac app rather than
/// a terminal. **Monospace is reserved for data**: timers, model IDs, hotkey
/// tokens, transcript metadata, token counts — anything where digit alignment
/// or a "machine value" connotation genuinely helps.
public enum BrutalistTypography {
    // ── UI chrome (system font, sentence case) ──────────────────────────
    /// Large page title (e.g. "Dictation Models").
    public static let title = Font.system(size: 22, weight: .semibold)
    /// Group / section header inside a page.
    public static let groupTitle = Font.system(size: 12, weight: .semibold)
    /// Primary row label.
    public static let label = Font.system(size: 13, weight: .regular)
    /// Emphasized row label.
    public static let labelEmphasis = Font.system(size: 13, weight: .medium)
    /// Running body copy.
    public static let body = Font.system(size: 13, weight: .regular)
    /// Secondary description / hint under a label.
    public static let caption = Font.system(size: 11, weight: .regular)
    /// Emphasized caption (status pills, "DEFAULT" tags rendered subtly).
    public static let captionEmphasis = Font.system(size: 11, weight: .medium)

    // ── Legacy semantic names (kept; now system font) ───────────────────
    public static let brandTitle = Font.system(size: 15, weight: .semibold)
    public static let sectionHeader = Font.system(size: 13, weight: .semibold)
    public static let sectionIndex = Font.system(size: 11, weight: .regular)
    public static let uiLabel = label
    public static let uiBody = body
    public static let uiMuted = caption

    // ── Data / technical (monospace) ────────────────────────────────────
    /// Transcript prose stays system font for readability.
    public static let transcriptBody = Font.system(size: 14, weight: .regular)
    /// …but transcript timestamps / speaker tags are monospace data.
    public static let transcriptMeta = Font.system(size: 10, weight: .regular, design: .monospaced)
    public static let mono10 = Font.system(size: 10, weight: .regular, design: .monospaced)
    public static let mono11 = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let mono12 = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let mono13 = Font.system(size: 13, weight: .regular, design: .monospaced)
}
