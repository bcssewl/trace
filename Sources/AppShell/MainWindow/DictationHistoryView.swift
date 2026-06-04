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

@MainActor
public struct DictationHistoryView: View {
    @Environment(\.brutalistPalette) private var palette
    @State private var model = DictationHistoryViewModel()
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
            } else if model.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
        // Keyed on projectID so switching projects re-queries for the new scope
        // even if SwiftUI reuses this view's identity.
        .task(id: projectID) { await model.reload(projectID: projectID) }
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
                ForEach(model.records, id: \.id) { record in
                    row(record)
                }
            }
            .padding(.vertical, 4)
        }
    }

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
                statusChip(record.inserted)
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
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    record.cleanedText.isEmpty ? record.rawText : record.cleanedText,
                    forType: .string
                )
            }
            Button("Delete", role: .destructive) {
                Task { await model.delete(record) }
            }
        }
    }

    private var dot: some View {
        Text("·").font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
    }

    private func statusChip(_ inserted: Bool) -> some View {
        BrutalistStatusChip(
            inserted ? "Inserted" : "Copied",
            tint: inserted ? palette.primary.color : palette.fgMuted.color
        )
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
