import SwiftUI

@MainActor
public struct TraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    public init() {}

    public var body: some Scene {
        Window("Trace", id: "main") {
            AppRootView(environment: delegate.environment)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        // Superset-style: title bar HIDDEN, NavigationSplitView columns extend
        // to the very top of the window, traffic lights overlay the sidebar's
        // top-left corner. The content column has its own internal toolbar.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Re-run Setup") {
                    delegate.environment.state.activeScene = .onboarding
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Search Library…") {
                    NotificationCenter.default.post(name: .traceOpenSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsRootView(appState: delegate.environment.state)
                .environment(\.brutalistPalette, delegate.environment.palette.dark)
        }
    }
}
