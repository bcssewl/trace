import Foundation

/// How the `Trace` executable was invoked.
///
/// The @main entry boots, then
/// switches on this value.
public enum AppLaunchMode: Equatable, Sendable {
    /// Normal GUI launch (NSApplicationMain + SwiftUI scene).
    case gui
    /// `--probe`: boot, print the boot report, exit 0. Used by smoke tests.
    case probe
}

/// Pure command-line parser for the executable's launch mode.
///
/// Unrecognized input
/// degrades gracefully to `.gui` — never throws or crashes on malformed flags.
public enum AppLaunchModeParser {
    public static func parse(_ arguments: [String]) -> AppLaunchMode {
        Array(arguments.dropFirst()).contains("--probe") ? .probe : .gui
    }
}
