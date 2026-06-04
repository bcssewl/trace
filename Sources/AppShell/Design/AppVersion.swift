import Foundation

/// The app's marketing version, read once from the bundle.
///
/// Single source of truth for the "vX.Y.Z" string shown in the menu-bar dropdown
/// and the About settings pane — no hardcoded placeholder, so the label always
/// reflects the real build (or is omitted when genuinely unavailable).
enum AppVersion {
    /// "v1.2.0" from `CFBundleShortVersionString`, or nil when the bundle carries
    /// no version string.
    static var label: String? {
        guard
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !version.isEmpty
        else { return nil }
        return "v\(version)"
    }
}
