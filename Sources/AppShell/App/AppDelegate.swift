import AppKit
import SharedCore
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let environment: AppEnvironment
    public let coordinator: AppRuntimeCoordinator
    public var commands: AppCommands { coordinator.commands }

    private var menuBarController: MenuBarController?
    private var coachOverlayController: CoachOverlayController?
    private var notchHudController: NotchHUDController?
    private var sparkleAdapter: SparkleUpdaterAdapter?
    public private(set) var updaterController: UpdaterController?

    public override init() {
        let env = AppEnvironment()
        self.environment = env
        self.coordinator = AppRuntimeCoordinator(environment: env)
        super.init()
    }

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.coordinator = AppRuntimeCoordinator(environment: environment)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        bootSparkle()
        menuBarController = MenuBarController(
            state: environment.state,
            palette: environment.palette,
            commands: commands
        )
        // Eagerly create the notch HUD so the coordinator can drive it on
        // capture lifecycle events. The HUD stays hidden until showCompact/
        // showWide/showDropdown is called.
        let hud = ensureNotchHUD()
        coordinator.notchHUD = hud
        // Eagerly create the coach overlay (hidden) so the coordinator can present
        // and drive it on meeting lifecycle + manual-trigger events.
        coordinator.coachOverlay = ensureCoachOverlay()
        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.makeKeyAndOrderFront(nil)
        }
        if ProcessInfo.processInfo.environment["TRACE_DUMP_WINDOWS"] != nil {
            dumpWindowState()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.dumpWindowState()
            }
        }
    }

    public func ensureCoachOverlay() -> CoachOverlayController {
        if let coachOverlayController { return coachOverlayController }
        let controller = CoachOverlayController(palette: environment.palette)
        coachOverlayController = controller
        return controller
    }

    public func ensureNotchHUD() -> NotchHUDController {
        if let notchHudController { return notchHudController }
        let controller = NotchHUDController(palette: environment.palette)
        notchHudController = controller
        return controller
    }

    private func dumpWindowState() {
        let path = "/tmp/trace-windows.txt"
        var lines: [String] = []
        lines.append("timestamp=\(Date().timeIntervalSince1970)")
        lines.append("activationPolicy=\(String(describing: NSApp.activationPolicy()))")
        lines.append("windowCount=\(NSApp.windows.count)")
        for (idx, window) in NSApp.windows.enumerated() {
            lines.append("")
            lines.append("window[\(idx)]")
            lines.append("  title=\(window.title)")
            lines.append("  identifier=\(window.identifier?.rawValue ?? "—")")
            lines.append("  visible=\(window.isVisible)")
            lines.append(
                "  frame=\(window.frame.origin.x),\(window.frame.origin.y) \(window.frame.width)x\(window.frame.height)"
            )
            lines.append("  level=\(window.level.rawValue)")
            lines.append("  styleMask=\(window.styleMask.rawValue)")
            lines.append("  sharingType=\(window.sharingType.rawValue)")
            if let content = window.contentView {
                describeTo(&lines, view: content, depth: 1)
            }
        }
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func describeTo(_ lines: inout [String], view: NSView, depth: Int) {
        guard depth < 6 else { return }
        let indent = String(repeating: "  ", count: depth)
        lines.append(
            "\(indent)\(type(of: view)) frame=\(view.frame.width)x\(view.frame.height) hidden=\(view.isHidden) subs=\(view.subviews.count)"
        )
        for sub in view.subviews {
            describeTo(&lines, view: sub, depth: depth + 1)
        }
    }

    private func describe(_ view: NSView, depth: Int = 0) -> [String: Any] {
        var subs: [[String: Any]] = []
        if depth < 4 {
            for sub in view.subviews {
                subs.append(describe(sub, depth: depth + 1))
            }
        }
        return [
            "class": String(describing: type(of: view)),
            "frame": ["w": view.frame.width, "h": view.frame.height],
            "isHidden": view.isHidden,
            "subviewCount": view.subviews.count,
            "subviews": subs,
        ]
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func bootSparkle() {
        let snapshot = BootContext.current
        guard let sparkleConfig = snapshot?.sparkleConfig else {
            Loggers.bootstrap.warning("Sparkle disabled — no validated config in BootContext")
            return
        }
        let adapter = SparkleUpdaterAdapter()
        self.sparkleAdapter = adapter
        self.updaterController = UpdaterController(driver: adapter, configuration: sparkleConfig)
        // Apply the persisted auto-update preference (BAS-24).
        self.updaterController?.setAutomaticChecks(enabled: environment.state.autoUpdatesEnabled)
        Loggers.bootstrap.info(
            "Sparkle updater wired with feed=\(sparkleConfig.feedURL.absoluteString, privacy: .public)")
        observeUpdaterNotifications()
    }

    /// Bridges Settings → Updates (a SwiftUI view) to the Sparkle updater the
    /// AppDelegate owns (BAS-24).
    private func observeUpdaterNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: .traceCheckForUpdates, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userRequestedCheckForUpdates() }
        }
        center.addObserver(forName: .traceUpdaterPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updaterController?.setAutomaticChecks(enabled: self.environment.state.autoUpdatesEnabled)
            }
        }
    }

    public func userRequestedCheckForUpdates() {
        updaterController?.checkForUpdates()
    }
}
