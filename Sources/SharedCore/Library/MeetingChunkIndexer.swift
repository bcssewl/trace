import Foundation
import os

/// Embeds a finalized meeting (transcript + scratchpad notes + summary) into the
/// unified `kb_chunks` store so cross-meeting Q&A can retrieve and cite it. The
/// transcript-side analogue of `KnowledgeBaseIndexer`, with two differences
/// dictated by the shared table:
///
///  1. **Provenance.** Every chunk carries its meeting id, project, title,
///     speaker(s), and (for transcript chunks) start timestamp, so a citation
///     can deep-link to `meeting @ ts`.
///  2. **Meeting-scoped purge.** It never calls the global `pruneObsolete`
///     (which the playbook indexer owns and which would wipe everything). On a
///     content change it purges only this meeting's rows via `deleteByMeeting`,
///     then re-embeds. When nothing changed (same content + same embedding
///     model) it skips entirely.
public actor MeetingChunkIndexer {

    public struct Report: Sendable {
        public var indexed: Int = 0
        public var embedded: Int = 0
        /// True when the meeting was already up-to-date and nothing was re-embedded.
        public var skipped: Bool = false
    }

    private let cache: KbCache
    private let embedder: EmbeddingClient
    private let config: EmbeddingConfig
    private let log = Loggers.library

    public init(cache: KbCache, embedder: EmbeddingClient, config: EmbeddingConfig) {
        self.cache = cache
        self.embedder = embedder
        self.config = config
    }

    /// - Parameter speakerNames: per-session display-name overrides keyed by raw
    ///   speaker id (e.g. `["remote_1": "Sarah"]`), captured at the finalize seam.
    ///   Absent ids fall back to the default `SpeakerLabel` labels (BAS-28).
    public func index(meeting: SavedMeeting, speakerNames: [String: String] = [:]) async throws -> Report {
        var report = Report()
        let meta = meeting.metadata
        let meetingId = meta.sessionId
        let title = meta.title ?? ""

        var prepared: [KbChunk] = []
        var desiredSignatures: Set<String> = []

        // --- Transcript ---
        let lines = meeting.utterances.map { utterance in
            let raw = utterance.speaker.rawValue
            let name =
                speakerNames[raw].flatMap { $0.isEmpty ? nil : $0 }
                ?? SpeakerLabel.display(forRawSpeaker: raw)
            return TranscriptChunker.Line(
                t: utterance.t,
                speaker: name,
                text: utterance.cleaned ?? utterance.text
            )
        }
        let transcriptChunks = TranscriptChunker.chunk(lines: lines, meetingTitle: title)
        if !transcriptChunks.isEmpty {
            let sourceFile = "meeting/\(meetingId)/transcript"
            let canonical = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let sha = KbCache.sha256Hex(of: Data(canonical.utf8))
            desiredSignatures.insert(signature(sourceFile, sha))
            for chunk in transcriptChunks {
                prepared.append(
                    KbChunk(
                        sourceFile: sourceFile,
                        breadcrumb: chunk.breadcrumb,
                        text: chunk.text,
                        sourceSha256: sha,
                        sourceKind: .transcript,
                        projectId: meta.projectId,
                        meetingId: meetingId,
                        speaker: chunk.speakers.isEmpty ? nil : chunk.speakers.joined(separator: ", "),
                        tsSeconds: chunk.tsStart,
                        title: title.isEmpty ? nil : title,
                        startedAt: meta.startedAt
                    ))
            }
        }

        // --- Notes + summary (markdown) ---
        appendMarkdownSource(
            meeting.notes, kind: .notes, sourceFile: "meeting/\(meetingId)/notes",
            meta: meta, title: title, into: &prepared, signatures: &desiredSignatures
        )
        if let summary = meeting.summary {
            appendMarkdownSource(
                summary, kind: .summary, sourceFile: "meeting/\(meetingId)/summary",
                meta: meta, title: title, into: &prepared, signatures: &desiredSignatures
            )
        }

        let existing = try await cache.indexedSignatures(meetingId: meetingId)
        report.indexed = prepared.count

        // --- Nothing changed (same content + embedding model): skip embedding,
        //     but still stamp so the reconcile's mtime gate is satisfied. ---
        if existing == desiredSignatures {
            report.skipped = true
            try await stampIndexed(meetingId)
            return report
        }

        // --- Per-source reconcile. Delete only the sources whose signature is no
        //     longer current — content changed, source removed, or embedding model
        //     changed — then (re-)embed only chunks not already present. Unchanged
        //     sources (e.g. the transcript when only the notes were edited) are left
        //     in place, so a notes edit no longer re-embeds the whole transcript. ---
        for staleSignature in existing.subtracting(desiredSignatures) {
            let file = String(staleSignature.split(separator: "|").first ?? "")
            try await cache.deleteByMeetingSource(meetingId: meetingId, sourceFile: file)
        }

        let toEmbed = prepared.filter { !existing.contains(signature($0.sourceFile, $0.sourceSha256)) }
        guard !toEmbed.isEmpty else {
            // Only removals happened (a source was deleted / emptied); nothing new.
            try await stampIndexed(meetingId)
            log.info(
                "meeting \(meetingId, privacy: .public) reconciled: \(existing.subtracting(desiredSignatures).count) source(s) pruned, none re-embedded"
            )
            return report
        }

        let vectors = try await embedder.embedForIndex(texts: toEmbed.map(\.text))
        precondition(
            vectors.count == toEmbed.count,
            "embedder returned \(vectors.count) vectors for \(toEmbed.count) chunks"
        )
        for (chunk, vector) in zip(toEmbed, vectors) {
            let embedding = KbEmbedding(
                chunkId: chunk.id, vector: vector, configFingerprint: config.fingerprint
            )
            try await cache.upsert(chunk: chunk, embedding: embedding, config: config)
            report.embedded += 1
        }
        try await stampIndexed(meetingId)
        log.info("indexed meeting \(meetingId, privacy: .public): \(report.embedded) chunks embedded")
        return report
    }

    private func stampIndexed(_ meetingId: String) async throws {
        try await cache.setLastIndexedAt(meetingId: meetingId, at: Int64(Date().timeIntervalSince1970))
    }

    private func appendMarkdownSource(
        _ raw: String,
        kind: KbChunk.SourceKind,
        sourceFile: String,
        meta: SessionMetadata,
        title: String,
        into prepared: inout [KbChunk],
        signatures: inout Set<String>
    ) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let outputs = MarkdownChunker.chunk(markdown: raw, sourceFile: sourceFile)
        guard !outputs.isEmpty else { return }
        let sha = KbCache.sha256Hex(of: Data(raw.utf8))
        signatures.insert(signature(sourceFile, sha))
        for output in outputs {
            prepared.append(
                KbChunk(
                    sourceFile: sourceFile,
                    breadcrumb: output.breadcrumb,
                    text: output.text,
                    sourceSha256: sha,
                    sourceKind: kind,
                    projectId: meta.projectId,
                    meetingId: meta.sessionId,
                    speaker: nil,
                    tsSeconds: nil,
                    title: title.isEmpty ? nil : title,
                    startedAt: meta.startedAt
                ))
        }
    }

    private func signature(_ sourceFile: String, _ sha: String) -> String {
        "\(sourceFile)|\(sha)|\(config.fingerprint)"
    }
}
