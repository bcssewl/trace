import Foundation
import os

/// Live watcher over a single folder.
///
/// Wraps a `DispatchSourceFileSystemObject`
/// on the directory's file descriptor; on each (debounced) write/rename/delete
/// event it rescans the folder for supported audio/video files and emits a
/// `FileBatchJob` for every newly-appeared file through `onJobs`. The diff
/// against the previously-seen set lives in `WatchedFolderSnapshot`, so each
/// file is emitted exactly once.
///
/// Modelled on `DeviceWatcher`: an `@unchecked Sendable` class whose mutable
/// state is confined behind an `OSAllocatedUnfairLock`, started/stopped
/// idempotently via a `SyncBool`. The directory scan is injectable (`scanner`)
/// so the backlog + incremental-diff orchestration is unit-testable without a
/// real `DispatchSource` — production passes `WatchedFolderScan.currentSupportedFiles`.
public final class WatchedFolderSession: @unchecked Sendable {

    /// Reads the set of currently-present supported files in a folder.
    ///
    /// Injected
    /// so tests drive the watcher deterministically with no real filesystem.
    public typealias Scanner = @Sendable (URL) -> Set<URL>

    private struct State {
        var folderURL: URL?
        var snapshot: WatchedFolderSnapshot
        var resolvedFolder: ResolvedFolder?
        var source: (any DispatchSourceFileSystemObject)?
        var fileDescriptor: Int32 = -1
        var pendingRescan: DispatchWorkItem?
    }

    public let config: WatchedFolderConfig
    public let origin: FileBatchJob.Origin
    private let scanner: Scanner
    private let onJobs: @Sendable ([FileBatchJob]) -> Void
    private let debounce: DispatchTimeInterval
    private let queue: DispatchQueue
    private let isRunning = SyncBool(initial: false)
    private let lock: OSAllocatedUnfairLock<State>

    public init(
        config: WatchedFolderConfig,
        origin: FileBatchJob.Origin = .watchedFolder,
        debounce: DispatchTimeInterval = .milliseconds(400),
        scanner: @escaping Scanner = { WatchedFolderScan.currentSupportedFiles(in: $0) },
        onJobs: @escaping @Sendable ([FileBatchJob]) -> Void
    ) {
        self.config = config
        self.origin = origin
        self.debounce = debounce
        self.scanner = scanner
        self.onJobs = onJobs
        self.queue = DispatchQueue(label: "trace.watched-folder", qos: .utility)
        self.lock = OSAllocatedUnfairLock(
            uncheckedState: State(snapshot: WatchedFolderSnapshot())
        )
    }

    deinit { stop() }

    /// Begin watching.
    ///
    /// Seeds the known-set from the folder's current contents,
    /// optionally emits a one-time backlog (when `importExistingOnFirstScan`),
    /// then installs the `DispatchSource`. Idempotent. A folder that can't be
    /// resolved/opened (e.g. iCloud not yet downloaded) seeds nothing and simply
    /// watches no events — `scanNow()` can still be driven later.
    public func start() {
        guard isRunning.compareAndSwap(expected: false, desired: true) else { return }

        let resolved = try? config.resolve()
        let url = resolved?.url ?? URL(fileURLWithPath: config.displayPath)
        let current = scanner(url)
        let importExisting = config.importExistingOnFirstScan

        lock.withLockUnchecked { state in
            state.folderURL = url
            state.resolvedFolder = resolved
            // importExisting → seed EMPTY so the first scan treats everything as
            // new; otherwise seed with the current set so only later arrivals fire.
            state.snapshot = WatchedFolderSnapshot(
                existing: importExisting ? [] : current,
                origin: origin,
                projectID: config.projectID,
                templateID: config.templateID
            )
        }

        installSource(url: url)

        if importExisting {
            let jobs = lock.withLockUnchecked { $0.snapshot.diff(currentFiles: current) }
            if !jobs.isEmpty {
                Loggers.files.info(
                    "WatchedFolderSession backlog: \(jobs.count, privacy: .public) existing file(s) from \(url.lastPathComponent, privacy: .public)"
                )
                onJobs(jobs)
            }
        }
    }

    /// Stop watching and release the security-scoped folder access.
    ///
    /// Idempotent.
    public func stop() {
        guard isRunning.compareAndSwap(expected: true, desired: false) else { return }
        lock.withLockUnchecked { state in
            state.pendingRescan?.cancel()
            state.pendingRescan = nil
            state.source?.cancel()  // cancel handler closes the fd
            state.source = nil
            state.fileDescriptor = -1
            state.resolvedFolder = nil  // ResolvedFolder.deinit releases the scope
        }
    }

    /// Rescan now and emit jobs for any files not seen before.
    ///
    /// Called by the
    /// debounced event handler and directly by the retroactive-import / manual
    /// "scan now" affordances. Synchronous (runs the scan on the caller's
    /// thread) so callers — and tests — observe emitted jobs immediately.
    public func scanNow() {
        performScan()
    }

    // MARK: - Internals

    private func performScan() {
        guard isRunning.value else { return }
        let url = lock.withLockUnchecked { $0.folderURL }
        guard let url else { return }
        let current = scanner(url)
        let jobs = lock.withLockUnchecked { state in state.snapshot.diff(currentFiles: current) }
        guard !jobs.isEmpty else { return }
        Loggers.files.info(
            "WatchedFolderSession detected \(jobs.count, privacy: .public) new file(s) in \(url.lastPathComponent, privacy: .public)"
        )
        onJobs(jobs)
    }

    private func installSource(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Loggers.files.warning(
                "WatchedFolderSession could not open \(url.path, privacy: .public) for watching (folder missing?); seeded set only"
            )
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.setCancelHandler { close(fd) }
        lock.withLockUnchecked { state in
            state.source = src
            state.fileDescriptor = fd
        }
        src.resume()
    }

    /// Coalesce a burst of filesystem events (a file copy fires many `.write`s)
    /// into a single rescan after `debounce`.
    private func scheduleRescan() {
        let work = DispatchWorkItem { [weak self] in self?.performScan() }
        lock.withLockUnchecked { state in
            state.pendingRescan?.cancel()
            state.pendingRescan = work
        }
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
