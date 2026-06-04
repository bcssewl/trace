import Foundation
/// `@_exported` re-export so `import DictationModule` lights up the full
/// dictation public surface from `SharedCore.Dictation` without callers
/// reaching past the wedge boundary.
@_exported import SharedCore

/// Wedge namespace.
///
/// AppShell uses `DictationModule.bootstrapRuntime(...)` to assemble the
/// long-lived actors and acquire a `Dictation.Runtime` handle.
public enum DictationModule {
    public static let moduleName = "DictationModule"

    /// Assembles the dictation runtime.
    ///
    /// Production callers pass live
    /// dependencies via the supplied factory closures; tests pass scripted
    /// equivalents.
    public static func bootstrapRuntime(
        controller: DictationController,
        modeRegistry: ModeRegistry,
        personalDictionary: PersonalDictionary,
        historyStore: DictationHistoryStore
    ) -> Dictation.Runtime {
        Dictation.Runtime(
            controller: controller,
            modeRegistry: modeRegistry,
            personalDictionary: personalDictionary,
            historyStore: historyStore
        )
    }
}
