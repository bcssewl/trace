import Foundation

/// Shared list-row formatting used across the library/history surfaces
/// (dictations, files, voice memos) so the formatter construction + format
/// strings live in one place rather than being copy-pasted per view.
enum RelativeFormat {
    /// Abbreviated relative time ("3m", "2h", "yesterday") for a date.
    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// A compact duration label: seconds under a minute ("45s"), else m:ss.
    static func durationLabel(ms: Int64) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
