import Foundation

/// Public, AppShell-facing entry point for the dictation wedge.
///
/// AppShell wires the actor graph through `Dictation.bootstrap(_:)` and then
/// drives the live system via the returned `DictationController` plus the MCP
/// server handle. Internals (state machine, mode registry, etc.) remain
/// accessible for tests but AppShell should not reach into them directly.
public enum Dictation {
    /// Bundles the long-lived dependencies the dictation wedge needs at
    /// runtime.
    ///
    /// AppShell builds this once at boot.
    public struct Runtime: Sendable {
        public let controller: DictationController
        public let modeRegistry: ModeRegistry
        public let personalDictionary: PersonalDictionary
        public let historyStore: DictationHistoryStore

        public init(
            controller: DictationController,
            modeRegistry: ModeRegistry,
            personalDictionary: PersonalDictionary,
            historyStore: DictationHistoryStore
        ) {
            self.controller = controller
            self.modeRegistry = modeRegistry
            self.personalDictionary = personalDictionary
            self.historyStore = historyStore
        }
    }

    /// Convenience: wires the controller against an explicit dependency bag.
    ///
    /// Production AppShell builds the deps from live components and passes
    /// them in. Tests pass a `ScriptedPipelineDeps`.
    public static func makeController(dependencies: any PipelineDependencies) -> DictationController {
        DictationController(dependencies: dependencies)
    }
}
