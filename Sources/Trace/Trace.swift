import AppShell
import Foundation
import SharedCore

/// Trace executable entry point.
///
/// MUST be a synchronous `main()`. Using `static func main() async` here was
/// causing Swift Concurrency's MainActor executor to deadlock against
/// NSApplicationMain — every MainActor hop (Task, DispatchQueue.main.async,
/// await on an isolated method) silently never resumed. See
/// [[project-task-executor-bug]].
@main
@MainActor
struct TraceMain {
    static func main() {
        let launchMode = AppLaunchModeParser.parse(CommandLine.arguments)

        // Bridge the async boot to sync via a semaphore. Safe because the
        // SwiftUI scene (and NSApplicationMain) has not started yet, so
        // blocking main here is fine — SqliteDatabase is an actor (no
        // MainActor isolation), and the detached Task runs on the
        // cooperative pool which doesn't need the main runloop.
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var bootOutcome: Swift.Result<AppLaunch.Result, Error>?
        Task.detached(priority: .high) {
            do {
                let result = try await AppLaunch().boot()
                bootOutcome = .success(result)
            } catch {
                bootOutcome = .failure(error)
            }
            sem.signal()
        }
        sem.wait()

        switch bootOutcome {
        case .success(let result):
            switch launchMode {
            case .probe:
                FileHandle.standardOutput.write(Data(probeReport(result).utf8))
                exit(0)
            case .gui:
                FileHandle.standardOutput.write(Data(probeReport(result).utf8))
                let projectStore = ProjectStore(database: result.database)
                BootContext.install(
                    BootContext.Snapshot(
                        database: result.database,
                        projectStore: projectStore,
                        config: result.config,
                        sparkleConfig: result.sparkleConfig
                    ))
                AppShell.launch()
            }
        case .failure(let error):
            FileHandle.standardError.write(Data("Trace launch failed: \(error)\n".utf8))
            exit(1)
        case .none:
            FileHandle.standardError.write(Data("Trace launch failed: bootstrap returned no result\n".utf8))
            exit(1)
        }
    }

    private static func probeReport(_ result: AppLaunch.Result) -> String {
        var lines: [String] = []
        lines.append("Trace — boot probe")
        lines.append("config.schemaVersion = \(result.config.schemaVersion)")
        lines.append("installer.outcome = \(result.installerOutcome)")
        if let sparkle = result.sparkleConfig {
            lines.append("sparkle.feedURL = \(sparkle.feedURL.absoluteString)")
            lines.append("sparkle.automaticChecks = \(sparkle.enableAutomaticChecks)")
        } else {
            lines.append("sparkle.config = <missing>")
        }
        if !result.sparkleValidationFailures.isEmpty {
            lines.append(
                "sparkle.warnings = \(result.sparkleValidationFailures.map(\.description).joined(separator: " | "))"
            )
        }
        lines.append("modules = SharedCore, AppShell")
        return lines.joined(separator: "\n") + "\n"
    }
}
