# Storage batch — integration notes

Audience: the orchestrating agent / whoever owns `AppRuntimeCoordinator` and the
view-models. Everything below is **outside the storage agent's file territory**
and needs a small amount of wiring (or is informational). All storage-side APIs
referenced here already exist, build, and are tested.

## 1. REQUIRED — run the launch reconcile pass at boot

New public API: `StorageReconciler` (Sources/SharedCore/Storage/StorageReconciler.swift).
It repairs FTS↔content desync, closes abandoned meetings (`ended_at IS NULL`
after a crash), and removes ghost/orphan index rows. Cheap on a clean DB
(signature-gated; two `stat`s per meeting).

In `AppRuntimeCoordinator`, alongside the existing launch reconciles
(`reconcileMeetingIndex()` / `reconcileEntryIndex()` / `reconcilePlaybookIndex()`,
around line 137), add — ideally FIRST, before the index reconciles, and before
any meeting can start:

```swift
// Launch-time storage integrity pass (FTS repair, abandoned-meeting closure,
// ghost cleanup). Must not be silent: surface failures and repairs.
if let db = database {
    do {
        let report = try await StorageReconciler(database: db).reconcile()
        if report.didRepairAnything {
            Loggers.storage.warning("\(report.summary, privacy: .public)")
            // OPTIONAL but preferred (no-silent-fallback): surface report.summary
            // in whatever boot-status/toast surface the shell has.
        }
    } catch {
        // Do NOT swallow: a failed integrity pass means search results may be
        // wrong. Surface a user-visible warning pointing at the issue.
        Loggers.storage.error("Storage reconcile failed: \(String(describing: error), privacy: .public)")
    }
}
```

Notes:
- Safe to re-run at any time; open meetings with transcript activity in the
  last 120 s are treated as live and untouched (`activityGrace:` parameter).
- The reconciler only sets `meetings.ended_at` for abandoned meetings (DB
  closure only, per task split). The meetings agent's "summary missing →
  generate" affordance composes on top.
- After a reconcile that repaired vector rows, the existing
  `ensureLibraryVectorSearch()?.refresh()` call picks changes up incrementally
  (refresh is now cheap — see §5).

## 2. REQUIRED — file-batch crash recovery at boot

New public API: `FileBatchController.recoverInterruptedJobs(maxAttempts:)`
(default 3) returning `RecoveryReport { requeued: [UUID]; abandoned: [UUID] }`.

`startRunLoop()` already self-recovers on its first run, **but** the controller
is constructed lazily on first ingest — so jobs stuck from a crash would sit
showing "Transcribing…" forever until the user happens to drop a new file. At
boot, add:

```swift
if let controller = await ensureFileBatchController() {
    do {
        let report = try await controller.recoverInterruptedJobs()
        if !report.requeued.isEmpty {
            await controller.startRunLoop()   // pass the usual locale/summarization
        }
        // report.abandoned rows are already marked failed with a user-visible
        // reason ("Processing was interrupted N times… use Retry").
    } catch {
        Loggers.files.error("File job recovery failed: \(String(describing: error), privacy: .public)")
        // Surface — stuck rows will otherwise show a perpetual spinner.
    }
}
```

Idempotent within one controller lifetime; calling it and then `startRunLoop()`
(which also tries) is fine.

## 3. RECOMMENDED — DictationHistoryStore delete should purge entry_fts

`Sources/SharedCore/Dictation/History/DictationHistoryStore.swift` (outside my
territory) deletes `dictations` rows without removing the matching `entry_fts`
row, so a deleted dictation ghosts in keyword search until the next entry
reconcile. (Files got the equivalent fix inside `FileRepository.delete`.)
Copy-paste fix — wrap the existing delete (line ~98):

```swift
try await database.transaction {
    try await database.withStatement(
        sql: "DELETE FROM entry_fts WHERE source = 'dictation' AND item_id = ?"
    ) { stmt in
        try stmt.bind(text: id, at: 1)
        _ = try stmt.step()
    }
    try await database.withStatement(sql: "DELETE FROM dictations WHERE id = ?") { stmt in
        try stmt.bind(text: id, at: 1)
        _ = try stmt.step()
    }
}
```

(The launch reconcile also sweeps such ghosts, so this is belt-and-braces.)

## 4. OPTIONAL — adopt keyset pagination in the meetings library model

The hard 500-row cap is GONE: `SessionRepository.listMeetings` /
`listInboxMeetings` / `FileRepository.list(origins:)` now default to unbounded
(metadata-only rows; the views render lazily and `MeetingsLibraryView` shows
100 rows at a time with automatic "Load more"). Nothing breaks if you change
nothing.

For true incremental DB loading later, additive API:

```swift
let page = try await repo.listMeetingsPage(projectId: nil, inboxOnly: false,
                                           after: nil, limit: 100)
// page.items, page.hasMore, page.nextCursor → pass back as `after:`
```

Wiring it means giving `MeetingLibraryModel` a paged `loadList` closure; the
view-side affordance already exists and would only need the sentinel's
`onAppear` to call the model instead of bumping a local window.

## 5. Behaviour changes inside existing signatures (FYI, no action)

- `SqliteDatabase.transaction` is now re-entrancy safe: nested calls (same
  task) flatten onto SAVEPOINTs; concurrent transactions from other tasks
  queue FIFO instead of corrupting each other. The body closure is now
  `@Sendable` (all in-repo callers were already compatible). **Do not** call
  `transaction` from a child task spawned and awaited inside another
  transaction body — that self-deadlocks (documented on the API).
- `PRAGMA synchronous` is now `FULL` (was `NORMAL`): an OS crash/power cut can
  no longer drop the most recent commits; costs one extra fsync per commit.
- `SessionRepository.deleteMeeting` now purges, transactionally: meetings row,
  transcript/notes FTS, `kb_chunks` + `kb_embeddings` (deleted meetings used
  to ghost in semantic search forever), `meeting_index_state`,
  `fts_reconcile_state`.
- `FtsIndex.upsertNotes`, `KbCache.upsert` / `pruneObsolete` /
  `deleteByMeeting` / `deleteByMeetingSource`, `LibraryEntryIndexer` upserts,
  `FileRepository.delete` — all multi-statement mutations are transactional now.
- `VectorSearch` stores vectors as packed half-precision blocks (≈½ RAM) and
  `refresh()` is incremental (id→version diff; only new/changed chunks load).
  Public API unchanged (`topK`, `indexedChunkCount`, `refresh`). Scores differ
  only by fp16 rounding.
- `LibraryStore.recentItems` pushes ORDER BY/LIMIT into each UNION branch;
  `entry_fts` source filtering is now a bound parameter.
- `FileBatchController.applyFailure` retries the failure write once and, if it
  still cannot persist, says so in the surfaced reason (the row is then healed
  by next-launch recovery).

## 6. Schema migrations used

- **v31** `fts_reconcile_state` (per-meeting transcript/notes signatures for
  the reconcile pass).
- **v32** `files.recovery_attempts` (crash-loop guard for job recovery).
- v33 remains free for this batch; nobody else may use v31–v33.

## 7. Dead code removed (task 9)

Deleted from `Sources/MeetingModule/`: `MeetingController.swift`,
`MeetingDependencies.swift`, `CaptureSession.swift`, `MergerOrchestrator.swift`
(orphaned pre-MeetingRuntime controller layer; repo-wide grep confirmed the
only references were their own tests). Their test classes were removed from
`Tests/MeetingModuleTests/MeetingModuleTests.swift`; tests of live types
(ConversationState*, categorization) kept and passing. `MeetingModule.swift`
(module marker) and `ConversationStateModel.swift` (live, used by the coach
pipeline) were checked and KEPT.
