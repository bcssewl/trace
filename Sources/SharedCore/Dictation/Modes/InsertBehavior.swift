import Foundation

/// How the cleaned dictation text lands in the target application.
///
/// Resolved per-mode and consumed by the `DictationController.paste(_:behavior:)` path.
public enum InsertBehavior: String, Sendable, Codable, Hashable, CaseIterable {
    /// Paste at the current cursor position via Accessibility (preferred).
    case pasteAtCursor
    /// Replace the current text selection if there is one; otherwise paste.
    case replaceSelection
    /// Append to a per-mode in-memory buffer rather than inserting into a target app.
    case appendToBuffer
}
