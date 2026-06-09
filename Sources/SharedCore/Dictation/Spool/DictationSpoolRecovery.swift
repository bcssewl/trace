import Foundation

/// Turns orphaned dictation spools (recordings whose session crashed before
/// finishing) back into text.
///
/// Owns the policy half of recovery: scan + cap enforcement (with a loud
/// history note for anything pruned), and the recover operation — transcribe
/// the spooled audio, persist the text to dictation history flagged
/// `recovered`, copy it to the clipboard, then delete the spool. The actual
/// speech-to-text pass is injected (`transcribe`), so this type stays free of
/// any concrete ASR backend and fully testable.
public actor DictationSpoolRecovery {

    private let directory: URL
    private let historyStore: DictationHistoryStore
    private let clipboard: any ClipboardStoring

    public init(
        directory: URL,
        historyStore: DictationHistoryStore,
        clipboard: any ClipboardStoring = PasteboardClipboard()
    ) {
        self.directory = directory
        self.historyStore = historyStore
        self.clipboard = clipboard
    }

    /// Recoverable spools, newest first.
    ///
    /// Also enforces the disk cap: spools pruned for age/size get a LOUD
    /// history note ("recording removed…") rather than vanishing silently.
    public func orphans() async -> [OrphanedDictationSpool] {
        let pruned = DictationSpoolStore.enforceCap(in: directory)
        for orphan in pruned {
            await recordPruneNote(for: orphan)
        }
        return DictationSpoolStore.orphanedSpools(in: directory)
    }

    /// Transcribes an orphaned spool, saves the text to dictation history
    /// (flagged recovered), copies it to the clipboard, and deletes the spool.
    ///
    /// Throws — keeping the spool on disk for a retry — when the audio cannot
    /// be read or the transcriber finds no speech in it.
    public func recover(
        _ orphan: OrphanedDictationSpool,
        transcribe: @Sendable ([Float]) async throws -> String
    ) async throws -> DictationRecord {
        let samples = try DictationSpoolStore.loadSamples(of: orphan)
        guard !samples.isEmpty else {
            throw TraceError.audioCaptureFailed(
                reason: "Recovered recording \(orphan.id) contains no audio"
            )
        }
        let text = try await transcribe(samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TraceError.asrInferenceFailed(
                engine: "recovery",
                reason: "No recognisable speech in the recovered audio"
            )
        }

        let record = DictationRecord(
            id: DictationRecord.newID(at: orphan.startedAt),
            projectID: nil,
            modeName: "Recovered",
            bundleID: nil,
            rawText: text,
            cleanedText: text,
            inserted: false,
            durationMs: Int(orphan.duration * 1_000),
            startedAt: orphan.startedAt.timeIntervalSince1970,
            recovered: true
        )
        try await historyStore.insert(record)
        await clipboard.writeString(text)
        DictationSpoolStore.discard(orphan)
        Loggers.dictation.info(
            "dictation spool recovered: \(orphan.id, privacy: .public) chars=\(text.count, privacy: .public)"
        )
        return record
    }

    /// Deletes a spool the user chose not to recover.
    public func discard(_ orphan: OrphanedDictationSpool) {
        DictationSpoolStore.discard(orphan)
    }

    /// Writes the loud "this was removed" note for a cap-pruned spool.
    private func recordPruneNote(for orphan: OrphanedDictationSpool) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: orphan.startedAt)
        let note =
            "A crashed dictation recording from \(when) "
            + "(\(Int(orphan.duration))s of audio) was removed without being recovered — "
            + "it exceeded the recovery storage limit."
        let record = DictationRecord(
            id: DictationRecord.newID(at: orphan.startedAt),
            projectID: nil,
            modeName: "Recovered",
            bundleID: nil,
            rawText: note,
            cleanedText: note,
            inserted: false,
            durationMs: Int(orphan.duration * 1_000),
            startedAt: orphan.startedAt.timeIntervalSince1970,
            recovered: true
        )
        do {
            try await historyStore.insert(record)
        } catch {
            Loggers.dictation.error(
                "spool prune note failed to persist: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
