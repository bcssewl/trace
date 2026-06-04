import Foundation
import SwiftUI

@MainActor
public struct AppRootView: View {
    @Environment(\.colorScheme) private var scheme
    public let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            switch environment.state.activeScene {
            case .onboarding:
                OnboardingRootView(
                    projectStore: environment.projectStore,
                    appState: environment.state,
                    asrInstall: environment.asrInstall,
                    onComplete: environment.state.markOnboardingComplete,
                    onOpenLibrary: environment.state.markOnboardingComplete,
                    // "Start using Trace" lands in the app but deliberately does NOT
                    // auto-open the mic — beginning a live recording the instant
                    // onboarding finishes was surprising. The user starts dictation
                    // themselves with the ⌥Space hotkey when they're ready.
                    onStartDictation: environment.state.markOnboardingComplete
                )
            case .main:
                MainWindowRootView(
                    projectStore: environment.projectStore,
                    captureState: environment.state.activeCapture,
                    appState: environment.state
                )
            }
        }
        .environment(\.brutalistPalette, environment.palette.resolve(effectiveScheme))
        .preferredColorScheme(environment.state.appearancePreference.preferredScheme)
        // When the user picks a new ASR engine or cleanup provider in
        // Settings, invalidate the cached LiveDictationRuntime so the next
        // ⌥Space rebuilds with the chosen backend + cleanup route.
        .onChange(of: environment.state.dictationASREngine) { _, _ in
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
        .onChange(of: environment.state.dictationCleanupProvider) { _, _ in
            NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
        }
    }

    /// Resolves the effective color scheme by combining the user's appearance
    /// preference (system / light / dark) with the system's current scheme.
    private var effectiveScheme: ColorScheme {
        switch environment.state.appearancePreference {
        case .system: return scheme
        case .light: return .light
        case .dark: return .dark
        }
    }
}
