import AppShell
import Foundation
import SharedCore
import SwiftUI

// MUST be a synchronous `main()`. See `Trace.swift` and
// [[project-task-executor-bug]] — an async main here breaks every MainActor
// scheduling primitive in the app once NSApplicationMain takes over the
// runloop. Bootstrap is bridged sync via a semaphore.
@main
@MainActor
struct TraceDevApp {
    static func main() {
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
            let projectStore = ProjectStore(database: result.database)
            BootContext.install(BootContext.Snapshot(
                database: result.database,
                projectStore: projectStore,
                config: result.config,
                sparkleConfig: result.sparkleConfig
            ))
        case .failure(let error):
            FileHandle.standardError.write(
                Data("TraceDev launch bootstrap failed: \(error)\n".utf8)
            )
        case .none:
            FileHandle.standardError.write(
                Data("TraceDev launch bootstrap returned no result\n".utf8)
            )
        }

        AppShell.launch()
    }
}
