import FluidAudio
import Foundation

public struct AsrModelSpec: Sendable, Hashable, Identifiable {
    public enum Backend: Sendable, Hashable {
        case parakeetTDT
        case liveDiarizer
        case offlineDiarizer
    }

    public let id: String
    public let displayName: String
    public let subtitle: String
    public let approximateBytes: Int64
    public let backend: Backend

    public init(
        id: String, displayName: String, subtitle: String,
        approximateBytes: Int64, backend: Backend
    ) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.approximateBytes = approximateBytes
        self.backend = backend
    }
}

public enum AsrModelDownloadStage: Sendable, Hashable {
    case queued
    case active(fraction: Double, bytesDownloaded: Int64)
    case completed
    case failed(reason: String)
    case alreadyPresent

    public var fraction: Double {
        switch self {
        case .queued, .failed: return 0
        case .active(let f, _): return f
        case .completed, .alreadyPresent: return 1
        }
    }
}

public struct AsrModelDownloadEvent: Sendable, Hashable {
    public let spec: AsrModelSpec
    public let stage: AsrModelDownloadStage

    public init(spec: AsrModelSpec, stage: AsrModelDownloadStage) {
        self.spec = spec
        self.stage = stage
    }
}

public enum AsrModelCatalog {
    public static let defaultSpecs: [AsrModelSpec] = [
        AsrModelSpec(
            id: "parakeet-tdt-v3",
            displayName: "Parakeet TDT v3 — multilingual",
            subtitle: "~700 MB · 25 languages · Apple Neural Engine",
            approximateBytes: 700_000_000,
            backend: .parakeetTDT
        ),
        AsrModelSpec(
            id: "live-diarizer",
            displayName: "Live Speaker Diarizer",
            subtitle: "~40 MB · streaming diarization · up to 10 speakers",
            approximateBytes: 40_000_000,
            backend: .liveDiarizer
        ),
        AsrModelSpec(
            id: "offline-diarizer",
            displayName: "Offline Diarizer (Pyannote)",
            subtitle: "~120 MB · post-meeting refinement",
            approximateBytes: 120_000_000,
            backend: .offlineDiarizer
        ),
    ]
}

public actor AsrModelDownloader {
    public init() {}

    public func download(_ specs: [AsrModelSpec]) -> AsyncStream<AsrModelDownloadEvent> {
        AsyncStream { continuation in
            let task = Task {
                for spec in specs {
                    if Task.isCancelled { break }
                    await self.run(spec: spec, continuation: continuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(spec: AsrModelSpec, continuation: AsyncStream<AsrModelDownloadEvent>.Continuation) async {
        let handler: DownloadUtils.ProgressHandler = { progress in
            let fraction = max(0, min(1, progress.fractionCompleted))
            let bytes = Int64(Double(spec.approximateBytes) * fraction)
            continuation.yield(
                AsrModelDownloadEvent(
                    spec: spec,
                    stage: .active(fraction: fraction, bytesDownloaded: bytes)
                ))
        }
        do {
            switch spec.backend {
            case .parakeetTDT:
                _ = try await AsrModels.download(progressHandler: handler)
            case .liveDiarizer:
                _ = try await DiarizerModels.downloadIfNeeded(progressHandler: handler)
            case .offlineDiarizer:
                _ = try await OfflineDiarizerModels.load(progressHandler: handler)
            }
            continuation.yield(AsrModelDownloadEvent(spec: spec, stage: .completed))
        } catch {
            continuation.yield(
                AsrModelDownloadEvent(
                    spec: spec,
                    stage: .failed(reason: error.localizedDescription)
                ))
        }
    }
}
