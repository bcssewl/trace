import SharedCore
import SwiftUI

/// Loads recent dictation records from `DictationHistoryStore` for the
/// Library → All Dictation view.
///
/// Backed by the shared boot database.
@MainActor
@Observable
final class DictationHistoryViewModel {
    private(set) var records: [DictationRecord] = []
    private(set) var loaded = false
    private let store: DictationHistoryStore?

    init() {
        if let db = BootContext.current?.database {
            self.store = DictationHistoryStore(database: db)
        } else {
            self.store = nil
        }
    }

    func reload(projectID: UUID? = nil) async {
        guard let store else {
            loaded = true
            return
        }
        do {
            records = try await store.recent(limit: 200, projectID: projectID)
        } catch {
            Loggers.bootstrap.error("DictationHistory load failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded = true
    }

    func delete(_ record: DictationRecord) async {
        guard let store else { return }
        try? await store.delete(id: record.id)
        records.removeAll { $0.id == record.id }
    }
}

/// Drives the "Recovered recordings" section: orphaned crash-recovery spools
/// found on disk, with Recover (transcribe → history + clipboard) and Discard.
///
/// Self-contained: builds a one-off batch ASR backend from the user's current
/// engine settings, so recovery works straight from the history view without
/// the dictation runtime having been constructed this session. Every failure
/// is surfaced in the section — nothing fails silently.
@MainActor
@Observable
final class DictationRecoveryViewModel {
    private(set) var orphans: [OrphanedDictationSpool] = []
    /// Spool currently being transcribed (disables its buttons + shows progress).
    private(set) var workingID: String?
    /// Human-readable progress ("Preparing speech model…" / "Transcribing…").
    private(set) var workingLabel: String = ""
    /// Last recovery error, shown loudly in the section until the next action.
    private(set) var errorMessage: String?
    /// Set briefly after a successful recovery so the UI can confirm the
    /// clipboard copy.
    private(set) var lastRecoveredID: String?

    private let store: DictationHistoryStore?

    init() {
        if let db = BootContext.current?.database {
            self.store = DictationHistoryStore(database: db)
        } else {
            self.store = nil
        }
    }

    func rescan() async {
        guard let store, let directory = try? DictationSpoolStore.defaultDirectory() else {
            // The launch notice may have sent the user here — an empty section
            // with no explanation would look like the recordings vanished.
            // List what's on disk (filesystem-only scan) and say why the
            // Recover buttons can't work right now.
            if let directory = try? DictationSpoolStore.defaultDirectory() {
                orphans = DictationSpoolStore.orphanedSpools(in: directory)
            } else {
                orphans = []
            }
            if !orphans.isEmpty {
                errorMessage =
                    "Recovery is unavailable right now — the app database did not open. The recordings are safe on disk; restart Trace and try again."
            }
            return
        }
        // The recovery actor's scan also enforces the disk cap, leaving a loud
        // history note for anything it prunes.
        let recovery = DictationSpoolRecovery(directory: directory, historyStore: store)
        orphans = await recovery.orphans()
    }

    /// Transcribes the spool with the user's configured dictation engine,
    /// saves it to history (flagged recovered), and copies it to the
    /// clipboard. Returns true on success so the caller can refresh the list.
    func recover(_ orphan: OrphanedDictationSpool) async -> Bool {
        guard let store else {
            errorMessage = "Recovery unavailable — the app database did not open."
            return false
        }
        guard let directory = try? DictationSpoolStore.defaultDirectory() else {
            errorMessage = "Recovery unavailable — the recordings folder could not be opened."
            return false
        }
        errorMessage = nil
        lastRecoveredID = nil
        workingID = orphan.id
        workingLabel = "Preparing speech model…"
        defer {
            workingID = nil
            workingLabel = ""
        }
        do {
            let backend = Self.currentBackend()
            try await backend.prepare(onStatus: { _ in }, onProgress: { _ in })
            workingLabel = "Transcribing…"
            let locale = Self.currentLocale()
            let recovery = DictationSpoolRecovery(directory: directory, historyStore: store)
            let record = try await recovery.recover(orphan) { samples in
                try await backend.transcribe(samples, locale: locale, previousContext: nil)
            }
            lastRecoveredID = record.id
            orphans.removeAll { $0.id == orphan.id }
            return true
        } catch {
            errorMessage = "Couldn't recover this recording: \(error.localizedDescription)"
            return false
        }
    }

    func discard(_ orphan: OrphanedDictationSpool) {
        errorMessage = nil
        DictationSpoolStore.discard(orphan)
        orphans.removeAll { $0.id == orphan.id }
    }

    /// The batch transcription backend matching the user's current Settings →
    /// ASR engine choice (same keys `AppRuntimeCoordinator` reads when it
    /// builds the live runtime).
    private static func currentBackend() -> any TranscriptionBackend {
        let defaults = UserDefaults.standard
        let engine =
            defaults.string(forKey: AppStateModel.dictationASRKey)
            .flatMap(DictationASREngine.init(rawValue:)) ?? .parakeet
        let cloud =
            defaults.string(forKey: AppStateModel.dictationCloudProviderKey)
            .flatMap(CloudASRProvider.init(rawValue:)) ?? .openai
        let localModelID = defaults.string(forKey: AppStateModel.dictationLocalModelKey)
        return ASREngineRegistry.backend(
            for: engine,
            cloudProvider: cloud,
            localModelID: (localModelID?.isEmpty == false) ? localModelID : nil
        )
    }

    private static func currentLocale() -> Locale {
        let language =
            UserDefaults.standard.string(forKey: AppStateModel.dictationLanguageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        return language.locale
    }
}

@MainActor
public struct DictationHistoryView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var model = DictationHistoryViewModel()
    @State private var recovery = DictationRecoveryViewModel()
    /// Briefly highlights the row whose text was just copied.
    @State private var copiedRecordID: String?
    /// When set, the list is scoped to this project's dictations; nil shows the
    /// global Library → All dictation history.
    private let projectID: UUID?

    public init(projectID: UUID? = nil) {
        self.projectID = projectID
    }

    public var body: some View {
        Group {
            if !model.loaded {
                loadingState
            } else if model.records.isEmpty && recovery.orphans.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
        // Keyed on projectID so switching projects re-queries for the new scope
        // even if SwiftUI reuses this view's identity.
        .task(id: projectID) {
            await model.reload(projectID: projectID)
            // Crash-recovery spools are global, not per-project — only the
            // unscoped history view surfaces them.
            if projectID == nil {
                await recovery.rescan()
            }
        }
        // Refresh when a new dictation finishes elsewhere in the app.
        .onReceive(NotificationCenter.default.publisher(for: .traceStopDictation)) { _ in
            Task {
                // brief delay so the just-finished record is persisted first
                try? await Task.sleep(nanoseconds: 600_000_000)
                await model.reload(projectID: projectID)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if projectID == nil && !recovery.orphans.isEmpty {
                    recoverySection
                }
                ForEach(model.records, id: \.id) { record in
                    row(record)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: recovered recordings

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.primary.color)
                Text("Recovered recordings")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.fg.color)
                Text("from a session that didn't finish")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if let message = recovery.errorMessage {
                Text(message)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.primary.color)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            ForEach(recovery.orphans) { orphan in
                recoveryRow(orphan)
            }
        }
        .background(palette.primary.color.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.borderSoft.color)
                .frame(height: BrutalistMetrics.hairline)
        }
    }

    private func recoveryRow(_ orphan: OrphanedDictationSpool) -> some View {
        let isWorking = recovery.workingID == orphan.id
        let anyWorking = recovery.workingID != nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.recoveryTitle(orphan))
                    .font(BrutalistTypography.body)
                    .foregroundStyle(palette.fg.color)
                Text("\(Self.relativeTime(orphan.startedAt.timeIntervalSince1970)) · \(Self.durationLabel(Int(orphan.duration * 1_000)))")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Spacer()
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(recovery.workingLabel)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
            } else {
                Button("Recover") {
                    Task {
                        if await recovery.recover(orphan) {
                            await model.reload(projectID: projectID)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(anyWorking)
                Button("Discard", role: .destructive) {
                    recovery.discard(orphan)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(anyWorking)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help("Recover transcribes this recording with your current speech engine, saves it to history, and copies the text to the clipboard.")
    }

    private static func recoveryTitle(_ orphan: OrphanedDictationSpool) -> String {
        "Unsaved dictation"
    }

    // MARK: history rows

    private func row(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.cleanedText.isEmpty ? record.rawText : record.cleanedText)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fg.color)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let mode = record.modeName, !mode.isEmpty {
                    Text(mode)
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                    dot
                }
                Text(Self.relativeTime(record.startedAt))
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                dot
                Text(Self.durationLabel(record.durationMs))
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
                Spacer()
                copyButton(record)
                statusChip(record)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.borderSoft.color)
                .frame(height: BrutalistMetrics.hairline)
                .padding(.leading, 14)
        }
        .contextMenu {
            Button("Copy text") { copy(record) }
            Button("Delete", role: .destructive) {
                Task { await model.delete(record) }
            }
        }
    }

    private func copyButton(_ record: DictationRecord) -> some View {
        Button {
            copy(record)
        } label: {
            Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    copiedRecordID == record.id ? palette.primary.color : palette.fgMuted.color)
        }
        .buttonStyle(.plain)
        .help("Copy text")
    }

    private func copy(_ record: DictationRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            record.cleanedText.isEmpty ? record.rawText : record.cleanedText,
            forType: .string
        )
        copiedRecordID = record.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedRecordID == record.id { copiedRecordID = nil }
        }
    }

    private var dot: some View {
        Text("·").font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
    }

    private func statusChip(_ record: DictationRecord) -> some View {
        let label: String
        let tint: Color
        if record.recovered {
            label = "Recovered"
            tint = palette.primary.color
        } else if record.inserted {
            label = "Inserted"
            tint = palette.primary.color
        } else {
            label = "Copied"
            tint = palette.fgMuted.color
        }
        return BrutalistStatusChip(label, tint: tint)
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    private var emptyState: some View {
        BrutalistEmptyState(
            symbol: "mic.slash",
            title: "No dictations yet",
            detail: "Press ⌥Space anywhere, talk, and your dictations land here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: formatting

    private static func relativeTime(_ epoch: TimeInterval) -> String {
        RelativeFormat.relativeTime(Date(timeIntervalSince1970: epoch))
    }

    private static func durationLabel(_ ms: Int) -> String {
        RelativeFormat.durationLabel(ms: Int64(ms))
    }
}
