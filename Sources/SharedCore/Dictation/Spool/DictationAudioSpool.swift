import Foundation
import os

/// Sidecar metadata written alongside each spool's raw PCM file.
///
/// Written ONCE, before the first audio byte, so even a spool that crashed one
/// buffer in carries enough context (sample rate + start time) to be recovered.
public struct DictationSpoolMetadata: Sendable, Codable, Equatable {
    /// Bump if the on-disk layout ever changes.
    public let formatVersion: Int
    /// Samples per second of the raw PCM payload (always 16 000 in practice).
    public let sampleRate: Double
    /// Wall-clock start of the recording (epoch seconds).
    public let startedAt: TimeInterval

    public init(formatVersion: Int = 1, sampleRate: Double, startedAt: TimeInterval) {
        self.formatVersion = formatVersion
        self.sampleRate = sampleRate
        self.startedAt = startedAt
    }
}

/// One recoverable spool found on disk — a recording whose owning session never
/// completed (crash, force-quit, power loss).
public struct OrphanedDictationSpool: Sendable, Equatable, Identifiable {
    public let id: String
    public let pcmURL: URL
    public let sidecarURL: URL
    public let startedAt: Date
    public let sampleRate: Double
    /// Raw payload size — 4 bytes per sample.
    public let byteCount: Int64

    public var sampleCount: Int { Int(byteCount) / MemoryLayout<Float32>.size }
    public var duration: TimeInterval {
        sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
    }

    public init(
        id: String, pcmURL: URL, sidecarURL: URL, startedAt: Date,
        sampleRate: Double, byteCount: Int64
    ) {
        self.id = id
        self.pcmURL = pcmURL
        self.sidecarURL = sidecarURL
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.byteCount = byteCount
    }
}

/// Incremental on-disk audio spool for crash-durable dictation.
///
/// While a dictation records, every 16 kHz mono chunk is appended here as raw
/// little-endian Float32 PCM through an unbuffered `FileHandle` — each `append`
/// reaches the kernel immediately, so an app crash or force-quit cannot lose
/// audio that has already been heard. A `.json` sidecar (sample rate + start
/// time) is written before the first byte.
///
/// Raw PCM was chosen over CAF/WAV deliberately: there is no header to finalise
/// (a half-written file is exactly as readable as a finished one), duration is
/// pure file size, and recovery feeds the batch ASR `[Float]` directly with no
/// decode step. `SystemAudioArchiver` keeps CAF because its consumer is an
/// `AVAudioFile` reader; this spool's only consumer is the transcriber.
///
/// Lifecycle: `finishClean()` after the transcript is safely extracted deletes
/// both files; `discard()` (user cancelled) does the same; anything else —
/// including the process dying — leaves them on disk for
/// `DictationSpoolStore.orphanedSpools` to find.
///
/// Single-owner: all calls come from the owning `BatchedASR` actor, so no
/// internal locking (matching `SystemAudioArchiver`).
public final class DictationAudioSpool {
    public let id: String
    public let pcmURL: URL
    public let sidecarURL: URL
    public private(set) var samplesWritten: Int = 0

    private var handle: FileHandle?

    /// Creates the spool directory if needed, writes the sidecar, opens the PCM
    /// file, and registers the id as ACTIVE so concurrent orphan scans skip it.
    public init(
        directory: URL,
        id: String = DictationAudioSpool.newID(),
        sampleRate: Double = 16_000,
        startedAt: Date = Date()
    ) throws {
        self.id = id
        self.pcmURL = directory.appendingPathComponent("\(id).pcm", isDirectory: false)
        self.sidecarURL = directory.appendingPathComponent("\(id).json", isDirectory: false)

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let metadata = DictationSpoolMetadata(
            sampleRate: sampleRate, startedAt: startedAt.timeIntervalSince1970
        )
        let sidecarData = try JSONEncoder().encode(metadata)
        try sidecarData.write(to: sidecarURL, options: .atomic)

        guard fm.createFile(atPath: pcmURL.path, contents: nil) else {
            try? fm.removeItem(at: sidecarURL)
            throw TraceError.storageFailed(
                reason: "dictation spool: could not create \(pcmURL.lastPathComponent)"
            )
        }
        do {
            self.handle = try FileHandle(forWritingTo: pcmURL)
        } catch {
            try? fm.removeItem(at: sidecarURL)
            try? fm.removeItem(at: pcmURL)
            throw TraceError.storageFailed(
                reason: "dictation spool: open for writing failed: \(error.localizedDescription)"
            )
        }
        DictationSpoolStore.registerActive(id)
    }

    deinit {
        // Process still alive but the spool was dropped without finish/discard
        // (a programming slip, not a crash): close the handle and leave the
        // files — better a spurious recoverable spool than silently lost audio.
        try? handle?.close()
        DictationSpoolStore.deregisterActive(id)
    }

    /// Appends mono Float32 samples (at the spool's sample rate). Each call is
    /// an immediate kernel write — no user-space buffering to lose in a crash.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, let handle else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw TraceError.storageFailed(
                reason: "dictation spool write failed: \(error.localizedDescription)"
            )
        }
        samplesWritten += samples.count
    }

    /// The cycle completed and its transcript is safely extracted — the spool
    /// has served its purpose. Closes and deletes both files.
    public func finishClean() {
        close(removingFiles: true)
    }

    /// The user deliberately abandoned this recording — delete it.
    public func discard() {
        close(removingFiles: true)
    }

    /// The cycle FAILED after capture (e.g. transcription threw). Close the
    /// handle but keep the files and deregister the id, so the recording shows
    /// up as recoverable straight away.
    public func keepForRecovery() {
        close(removingFiles: false)
    }

    private func close(removingFiles: Bool) {
        if let handle {
            try? handle.close()
            self.handle = nil
        }
        if removingFiles {
            try? FileManager.default.removeItem(at: pcmURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        DictationSpoolStore.deregisterActive(id)
    }

    public static func newID(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let uniq = String(UUID().uuidString.prefix(4))
        return "spool_\(formatter.string(from: date))_\(uniq)"
    }
}

/// Filesystem-level operations over the spool directory: locating orphans,
/// loading their audio, discarding them, and bounding total disk use.
public enum DictationSpoolStore {

    /// Spools live under `Application Support/Trace/dictation-spools`.
    public static func defaultDirectory() throws -> URL {
        let support = try DatabasePaths().applicationSupportDirectory()
        return support.appendingPathComponent("dictation-spools", isDirectory: true)
    }

    /// Total spool payload allowed on disk before the oldest orphans are pruned
    /// (~6.5 hours of 16 kHz mono Float32).
    public static let maxSpoolBytes: Int64 = 750 * 1_024 * 1_024
    /// Orphans older than this are pruned as ancient.
    public static let maxSpoolAge: TimeInterval = 30 * 24 * 60 * 60

    /// Spools the CURRENT process is actively writing — skipped by orphan scans
    /// so a recording in progress can never be "recovered" out from under
    /// itself. Orphans from a crashed previous session can never be in here.
    private static let activeIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func registerActive(_ id: String) {
        activeIDs.withLock { _ = $0.insert(id) }
    }

    static func deregisterActive(_ id: String) {
        activeIDs.withLock { _ = $0.remove(id) }
    }

    static func isActive(_ id: String) -> Bool {
        activeIDs.withLock { $0.contains(id) }
    }

    /// Spools left behind by a session that never completed, newest first.
    ///
    /// A spool qualifies when its `.pcm` + `.json` pair exists, it isn't being
    /// written by this process, and it contains at least a sliver of audio
    /// (sub-0.2 s spools are deleted on sight — there is nothing to recover).
    public static func orphanedSpools(in directory: URL) -> [OrphanedDictationSpool] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )
        else { return [] }

        var orphans: [OrphanedDictationSpool] = []
        for pcmURL in entries where pcmURL.pathExtension == "pcm" {
            let id = pcmURL.deletingPathExtension().lastPathComponent
            guard !isActive(id) else { continue }
            let sidecarURL = directory.appendingPathComponent("\(id).json", isDirectory: false)
            guard let sidecarData = try? Data(contentsOf: sidecarURL),
                let metadata = try? JSONDecoder().decode(DictationSpoolMetadata.self, from: sidecarData)
            else {
                // PCM without a readable sidecar can't be interpreted — remove
                // the stray file rather than rescanning it forever.
                Loggers.dictation.error(
                    "dictation spool \(id, privacy: .public) has no readable sidecar — removing"
                )
                try? fm.removeItem(at: pcmURL)
                try? fm.removeItem(at: sidecarURL)
                continue
            }
            let byteCount =
                (try? pcmURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let orphan = OrphanedDictationSpool(
                id: id,
                pcmURL: pcmURL,
                sidecarURL: sidecarURL,
                startedAt: Date(timeIntervalSince1970: metadata.startedAt),
                sampleRate: metadata.sampleRate,
                byteCount: byteCount
            )
            if orphan.duration < 0.2 {
                try? fm.removeItem(at: pcmURL)
                try? fm.removeItem(at: sidecarURL)
                continue
            }
            orphans.append(orphan)
        }
        return orphans.sorted { $0.startedAt > $1.startedAt }
    }

    /// Reads a spool's full PCM payload back as Float samples.
    public static func loadSamples(of orphan: OrphanedDictationSpool) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: orphan.pcmURL)
        } catch {
            throw TraceError.storageFailed(
                reason: "dictation spool read failed: \(error.localizedDescription)"
            )
        }
        let count = data.count / MemoryLayout<Float32>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest, count: count * MemoryLayout<Float32>.size)
        }
        return samples
    }

    /// Deletes an orphan's files.
    public static func discard(_ orphan: OrphanedDictationSpool) {
        try? FileManager.default.removeItem(at: orphan.pcmURL)
        try? FileManager.default.removeItem(at: orphan.sidecarURL)
    }

    /// Bounds the spool directory: prunes orphans older than `maxAge`, then —
    /// oldest first — anything beyond `maxBytes` total. Returns what was pruned
    /// so the caller can leave a loud trace (a history note), never a silent
    /// deletion.
    public static func enforceCap(
        in directory: URL,
        maxBytes: Int64 = DictationSpoolStore.maxSpoolBytes,
        maxAge: TimeInterval = DictationSpoolStore.maxSpoolAge,
        now: Date = Date()
    ) -> [OrphanedDictationSpool] {
        let orphans = orphanedSpools(in: directory)  // newest first
        var pruned: [OrphanedDictationSpool] = []
        var kept: [OrphanedDictationSpool] = []
        for orphan in orphans {
            if now.timeIntervalSince(orphan.startedAt) > maxAge {
                pruned.append(orphan)
            } else {
                kept.append(orphan)
            }
        }
        // `kept` is newest-first; accumulate from the newest and prune the
        // overflow at the old end.
        var total: Int64 = 0
        for orphan in kept {
            total += orphan.byteCount
            if total > maxBytes {
                pruned.append(orphan)
            }
        }
        for orphan in pruned {
            discard(orphan)
            Loggers.dictation.error(
                "dictation spool pruned (cap): \(orphan.id, privacy: .public) duration=\(Int(orphan.duration), privacy: .public)s"
            )
        }
        return pruned
    }
}
