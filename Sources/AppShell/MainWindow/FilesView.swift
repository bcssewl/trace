import AppKit
import SharedCore
import SwiftUI

/// Which capture surface a `FileBatchListView` is showing — drives the empty
/// state copy and the top action bar (file picker + drop vs. record).
public enum FileBatchSurface: Sendable, Hashable {
    case files
    case voiceMemos

    var origins: Set<FileBatchJob.Origin> {
        switch self {
        case .files: return FileRecord.fileOrigins
        case .voiceMemos: return FileRecord.voiceMemoOrigins
        }
    }
}

/// The Files surface — the batch queue + completed list.
///
/// Replaces
/// `FileBatchPlaceholderView`. `projectID` non-nil scopes it to one project.
@MainActor
public struct FilesView: View {
    let model: FileBatchModel?
    let projectID: String?
    public init(model: FileBatchModel?, projectID: String? = nil) {
        self.model = model
        self.projectID = projectID
    }
    public var body: some View {
        FileBatchListView(model: model, surface: .files, projectID: projectID)
    }
}

/// The Voice Memos surface — captured + iCloud-synced memos.
///
/// Replaces
/// `DictationListPlaceholderView` for the Voice Memos category.
@MainActor
public struct VoiceMemosView: View {
    let model: FileBatchModel?
    let projectID: String?
    public init(model: FileBatchModel?, projectID: String? = nil) {
        self.model = model
        self.projectID = projectID
    }
    public var body: some View {
        FileBatchListView(model: model, surface: .voiceMemos, projectID: projectID)
    }
}

@MainActor
struct FileBatchListView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    let model: FileBatchModel?
    let surface: FileBatchSurface
    let projectID: String?

    @State private var isDropTargeted = false
    @State private var playback = MemoPlaybackModel()

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
        .modifier(FileDropModifier(enabled: surface == .files, isTargeted: $isDropTargeted, onDrop: enqueue))
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(palette.primary.color, lineWidth: 2)
                    .background(palette.primary.color.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .task(id: scopeKey) {
            // Switching project/surface swaps the whole list out — stop any clip
            // that was playing so it doesn't keep going under a different scope.
            playback.stop()
            await model?.show(origins: surface.origins, projectID: projectID)
        }
        // Stop any playback when leaving the surface so audio doesn't keep playing
        // after you navigate away.
        .onDisappear { playback.stop() }
    }

    /// Re-runs the scoped load whenever the surface or project changes.
    private var scopeKey: String { "\(surface)-\(projectID ?? "all")" }

    private var records: [FileRecord] { model?.records ?? [] }

    // MARK: Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            switch surface {
            case .files:
                BrutalistButton("Pick files…", kind: .primary) { pickFiles() }
                Text("…or drop audio / video anywhere here")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            case .voiceMemos:
                BrutalistButton("Record voice memo", kind: .primary) {
                    NotificationCenter.default.post(name: .traceStartVoiceMemo, object: nil)
                }
                Text("⌥V anywhere, or sync from iPhone in Settings → Watched Folders")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Spacer()
            if let n = inFlightCount, n > 0 {
                Text("\(n) in progress")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private var inFlightCount: Int? {
        guard let model else { return nil }
        return records.filter { model.isInFlight($0) }.count
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { record in
                        row(record)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let isFiles = surface == .files
        BrutalistEmptyState(
            symbol: isFiles ? "square.and.arrow.down" : "waveform",
            title: isFiles ? "Transcribe a file" : "No voice memos yet",
            detail: isFiles
                ? "Drop in audio or video, or pick files to queue for transcription."
                : "Press ⌥V to record, or enable iPhone Voice Memo sync in Settings.",
            actionTitle: isFiles ? "Pick files…" : nil,
            action: isFiles ? { pickFiles() } : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row

    private func row(_ record: FileRecord) -> some View {
        let status = model?.effectiveStatus(for: record) ?? record.status
        let inFlight = model?.isInFlight(record) ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon(for: record.kind))
                    .font(.system(size: 13))
                    .foregroundStyle(inFlight ? palette.primary.color : palette.fgMuted.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title ?? "Untitled")
                        .font(BrutalistTypography.body)
                        .foregroundStyle(palette.fg.color)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        BrutalistStatusChip(statusLabel(status), tint: statusColor(status))
                        dot
                        Text(RelativeFormat.relativeTime(record.createdAt))
                            .font(BrutalistTypography.caption)
                            .foregroundStyle(palette.fgMuted.color)
                        if let ms = record.durationMs, ms > 0 {
                            dot
                            Text(RelativeFormat.durationLabel(ms: ms))
                                .font(BrutalistTypography.mono10)
                                .foregroundStyle(palette.fgMuted.color)
                        }
                    }
                }
                Spacer()
                if inFlight {
                    Button {
                        cancel(record)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.fgMuted.color)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                } else if status == .completed {
                    BrutalistButton("Open", kind: .ghost, size: .compact) {
                        model?.openTranscript?(record)
                    }
                }
            }
            if inFlight {
                ProgressView(value: model?.progress(for: record) ?? 0)
                    .progressViewStyle(.linear)
                    .tint(palette.primary.color)
            }
            // In-app playback for captured/synced voice memos so you can listen
            // back without digging the file out of Finder. Hidden while the audio
            // is still being extracted (nothing to play yet).
            if surface == .voiceMemos, !inFlight {
                memoPlaybackBar(record)
            }
            if status == .failed, let reason = record.errorReason {
                Text(reason)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.borderSoft.color)
                .frame(height: BrutalistMetrics.hairline)
                .padding(.leading, 14)
        }
        .contextMenu { rowMenu(record, status: status) }
    }

    @ViewBuilder
    private func rowMenu(_ record: FileRecord, status: FileBatchStatus) -> some View {
        if status == .completed {
            Button("Open transcript") { model?.openTranscript?(record) }
        }
        Button("Reveal source in Finder") { model?.revealInFinder?(record.sourcePath) }
        if status == .failed || status == .cancelled {
            Button("Retry") { Task { await model?.retry(record) } }
        }
        Divider()
        Button("Delete", role: .destructive) {
            // Stop playback first if we're deleting the clip that's playing — its
            // row (and controls) vanish, so otherwise it'd keep playing unstoppably.
            if playback.playingID == record.id { playback.stop() }
            Task { await model?.delete(record) }
        }
    }

    private var dot: some View {
        Text("·").font(BrutalistTypography.caption).foregroundStyle(palette.fgMuted.color)
    }

    // MARK: Playback

    @ViewBuilder
    private func memoPlaybackBar(_ record: FileRecord) -> some View {
        if playback.failedID == record.id {
            Text("Couldn’t play this recording — the audio file may be missing.")
                .font(BrutalistTypography.caption)
                .foregroundStyle(BrutalistPalette.semantic(scheme).warning.color)
                .padding(.top, 2)
        } else {
            let isActive = playback.playingID == record.id
            // Fall back to the persisted duration so the scrubber shows a full
            // track even before you press play.
            let total = isActive && playback.duration > 0
                ? playback.duration
                : Double(record.durationMs ?? 0) / 1000
            let position = isActive ? playback.currentTime : 0
            HStack(spacing: 10) {
                Button {
                    playback.toggle(record)
                } label: {
                    Image(systemName: isActive && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.primary.color)
                }
                .buttonStyle(.plain)
                .help(isActive && playback.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { position },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(total, 0.1)
                )
                .controlSize(.mini)
                .disabled(!isActive)

                Text("\(TranscriptChunker.timeLabel(position)) / \(TranscriptChunker.timeLabel(total))")
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
                    .monospacedDigit()
            }
            .padding(.top, 2)
        }
    }

    // MARK: Actions

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        enqueue(panel.urls)
    }

    private func enqueue(_ urls: [URL]) {
        guard let model, !urls.isEmpty else { return }
        Task { await model.enqueue(urls) }
    }

    private func cancel(_ record: FileRecord) {
        guard let model, let id = UUID(uuidString: record.id) else { return }
        Task { await model.cancel(id) }
    }

    // MARK: Display helpers

    private func icon(for kind: FileBatchJob.Kind) -> String {
        switch kind {
        case .audio: return "waveform"
        case .video: return "film"
        case .voiceMemo: return "mic"
        }
    }

    private func statusLabel(_ status: FileBatchStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .extracting: return "Extracting audio…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarising…"
        case .writing: return "Saving…"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func statusColor(_ status: FileBatchStatus) -> Color {
        switch status {
        case .completed: return BrutalistPalette.semantic(scheme).success.color
        case .failed: return BrutalistPalette.semantic(scheme).warning.color
        case .cancelled: return palette.fgMuted.color
        default: return palette.primary.color
        }
    }

}

/// Conditionally attaches a file drop target (only the Files surface accepts
/// drops).
///
/// Kept as a modifier so the empty + list states share one definition.
@MainActor
private struct FileDropModifier: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return !urls.isEmpty
            } isTargeted: {
                isTargeted = $0
            }
        } else {
            content
        }
    }
}
