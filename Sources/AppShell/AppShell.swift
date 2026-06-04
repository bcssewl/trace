import CoachModule
import DictationModule
import FileBatchModule
import Foundation
import MeetingModule
import SharedCore

/// Top-level marker for the `AppShell` umbrella target.
///
/// The UI surfaces
/// (menu bar, notch HUD, main window, coach overlay) compose under this
/// module, but the runtime entry point lives in `AppLaunch` so the
/// `Trace` executable can stay tiny.
public enum AppShell {
    public static let moduleName = "AppShell"

    @MainActor
    public static func launch() {
        TraceApp.main()
    }
}
