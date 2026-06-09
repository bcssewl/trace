import Foundation
import Observation
import SharedCore

/// Owns the on-device speech-model download for its whole lifetime.
///
/// This used to live inside `OnboardingStateModel`, which is `@State` on the
/// wizard view — so the moment the user tapped "Start dictating" / "Open
/// Library" and the scene flipped to `.main`, the view (and its download task)
/// were torn down and the download was silently cancelled, even though the Done
/// screen promised it kept going in the background. Hoisting it here, owned by
/// the long-lived `AppEnvironment`, means an approved download survives leaving
/// onboarding and the dictation runtime can wait on the same instance.
///
/// Scope: only the essential ASR backbone (Parakeet TDT) — the model both
/// dictation and meeting capture run on by default. The diarizer models are
/// beta and off by default, so they download lazily when the user enables
/// diarization, not here.
@Observable
@MainActor
public final class AsrModelInstallCoordinator {
    public enum Phase: Sendable, Hashable {
        /// Nothing requested yet — show the "Download" affordance.
        case idle
        /// A download task is running.
        case downloading
        /// The task finished (check `parakeetReady` for whether it succeeded).
        case finished
    }

    public private(set) var phase: Phase = .idle
    /// Per-model download stage, keyed by spec id — drives the onboarding
    /// progress rows.
    public private(set) var events: [String: AsrModelDownloadStage] = [:]
    /// Whether the Parakeet weights are on disk and ready to load.
    ///
    /// This is the
    /// single gate the dictation runtime consults.
    public private(set) var parakeetReady: Bool = false {
        didSet { if parakeetReady && !oldValue { onParakeetReady?() } }
    }

    /// Fired (on the main actor) the moment `parakeetReady` flips on — whether
    /// via a disk probe or a finishing download. `AppEnvironment` uses it to
    /// honour a deferred engine take-over: when the onboarding practice had to
    /// run on Apple Speech because Parakeet was still downloading, it promises
    /// the user Parakeet takes over once the download lands — this is the hook
    /// that keeps that promise.
    public var onParakeetReady: (@MainActor () -> Void)?

    /// The models this coordinator installs (essential dictation/meeting set).
    public let specs: [AsrModelSpec]

    private let downloader: AsrModelDownloader
    private var downloadTask: Task<Void, Never>?

    private static let parakeetSpecID = "parakeet-tdt-v3"

    public init(
        downloader: AsrModelDownloader = AsrModelDownloader(),
        specs: [AsrModelSpec] = AsrModelCatalog.defaultSpecs.filter { $0.backend == .parakeetTDT }
    ) {
        self.downloader = downloader
        self.specs = specs.isEmpty ? AsrModelCatalog.defaultSpecs : specs
        for spec in self.specs { self.events[spec.id] = .queued }
    }

    public var isDownloading: Bool { phase == .downloading }

    /// `true` once a download finished but Parakeet still isn't ready — i.e. it
    /// failed and should offer a retry.
    public var didFail: Bool { phase == .finished && !parakeetReady }

    /// 0…1 progress of the Parakeet model specifically (the dictation gate).
    public var parakeetFraction: Double {
        (events[Self.parakeetSpecID] ?? .queued).fraction
    }

    /// Weighted 0…1 progress across every installed spec (the total bar).
    public var totalFraction: Double {
        let total = specs.reduce(0.0) { $0 + Double($1.approximateBytes) }
        guard total > 0 else { return 0 }
        let done = specs.reduce(0.0) { $0 + Double($1.approximateBytes) * (events[$1.id] ?? .queued).fraction }
        return done / total
    }

    /// Refresh `parakeetReady` from disk (the FluidAudio cache).
    ///
    /// Only ever flips
    /// it ON — a download in flight shouldn't be clobbered to `false` by a probe
    /// that races the file write. Deliberately a bare filesystem check (not the
    /// full `DictationAvailabilityProbe`, which also pings Ollama on a 1.2s
    /// timeout) so a ⌥Space with the model already cached starts instantly.
    public func probeReadiness() async {
        if parakeetReady { return }
        if Self.parakeetCachedOnDisk() { parakeetReady = true }
    }

    /// Mirror of `DictationAvailabilityProbe.checkParakeet` — the FluidAudio
    /// cache dir exists and is non-empty.
    private static func parakeetCachedOnDisk() -> Bool {
        let fm = FileManager.default
        guard
            let support = try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
        else { return false }
        let dir =
            support
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return !contents.isEmpty
    }

    /// Begin (or resume) the download.
    ///
    /// Idempotent — calling it again while a
    /// download is already running is a no-op.
    public func start() {
        guard downloadTask == nil else { return }
        phase = .downloading
        let specs = self.specs
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.downloader.download(specs)
            for await event in stream {
                self.events[event.spec.id] = event.stage
                if event.spec.id == Self.parakeetSpecID {
                    switch event.stage {
                    case .completed, .alreadyPresent: self.parakeetReady = true
                    default: break
                    }
                }
            }
            self.downloadTask = nil
            self.phase = .finished
        }
    }

    /// Cancel an in-flight download.
    ///
    /// Any model that already finished stays on
    /// disk; the step returns to a re-startable state.
    public func pause() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = parakeetReady ? .finished : .idle
    }

    /// Ensure the Parakeet model is present — starting the download if needed
    /// and awaiting it — then report whether it's ready.
    ///
    /// This is what lets a
    /// ⌥Space with no model downloaded *wait for the download* instead of
    /// dead-ending, and is why dictation never silently falls back to another
    /// engine.
    @discardableResult
    public func ensureParakeet() async -> Bool {
        await probeReadiness()
        if parakeetReady { return true }
        start()
        await downloadTask?.value
        return parakeetReady
    }
}
