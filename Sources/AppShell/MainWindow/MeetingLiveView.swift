import SharedCore
import SwiftUI

/// The live, bound tri-column meeting view (Transcript / My Notes / AI Summary).
///
/// Reads the single source of truth `MeetingLiveModel`; the My-Notes editor
/// writes back and debounce-persists to `notes.md` through the model's
/// runtime-provided sink.
@MainActor
struct MeetingLiveView: View {
    @Environment(\.brutalistPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: MeetingLiveModel
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var showSteer = false
    @State private var steerText = ""
    /// The speaker currently being renamed (drives the rename sheet), plus its
    /// editable name.
    ///
    /// Renaming a remote speaker applies for this meeting and — with
    /// cross-meeting memory on — is remembered for future meetings (BAS-11).
    @State private var renamingSpeakerID: String?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            transcriptColumn
            columnDivider
            notesColumn
            columnDivider
            summaryColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
        .sheet(
            isPresented: Binding(
                get: { renamingSpeakerID != nil },
                set: { if !$0 { renamingSpeakerID = nil } }
            )
        ) { renameSpeakerSheet }
    }

    // MARK: Speaker rename (BAS-11)

    private func startRename(_ speakerID: String) {
        renameText = model.displayName(for: speakerID)
        renamingSpeakerID = speakerID
    }

    private func commitRename() {
        if let speakerID = renamingSpeakerID {
            model.renameSpeaker(speakerID, to: renameText)
        }
        renamingSpeakerID = nil
    }

    private var renameSpeakerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename speaker")
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            BrutalistTextField("Name", text: $renameText)
            Text(
                "Applies to this meeting. With “Remember speakers across meetings” on, this voice is recognised in future meetings — stored on your Mac only."
            )
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                BrutalistButton("Cancel", kind: .ghost) { renamingSpeakerID = nil }
                    .keyboardShortcut(.cancelAction)
                BrutalistButton("Save", kind: .primary, action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.background.color)
    }

    private var columnDivider: some View {
        Rectangle().fill(palette.borderSoft.color).frame(width: BrutalistMetrics.hairline)
    }

    // MARK: Transcript

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            columnHeader("Transcript") { transcriptStatus }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.turns.isEmpty && activePartials.isEmpty {
                            Text("Listening… spoken audio appears here as people talk.")
                                .font(BrutalistTypography.body)
                                .foregroundStyle(palette.fgMuted.color)
                                .padding(.top, 24)
                        }
                        ForEach(model.turns) { turn in
                            turnRow(turn).id(turn.id)
                        }
                        ForEach(activePartials, id: \.speakerID) { partial in
                            partialRow(partial)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.turns.count) { _, _ in
                    guard let last = model.turns.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                // Seek to a cited timestamp — both on change (already mounted) and
                // on appear (target set during the async open, before this mounts).
                .onChange(of: model.scrollTargetTime) { _, target in
                    seekTranscript(to: target, proxy: proxy)
                }
                .onAppear { seekTranscript(to: model.scrollTargetTime, proxy: proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scroll to the turn whose timestamp is nearest `target` (seconds from
    /// start).
    ///
    /// Identifies the target by `t`, since `Turn.id` is not stable
    /// across reloads.
    private func seekTranscript(to target: Double?, proxy: ScrollViewProxy) {
        guard let target,
            let match = model.turns.min(by: { abs($0.t - target) < abs($1.t - target) })
        else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(match.id, anchor: .center) }
    }

    @ViewBuilder
    private var transcriptStatus: some View {
        let semantic = BrutalistPalette.semantic(scheme)
        switch model.health {
        case .capturing:
            BrutalistStatusChip("Live", tint: palette.primary.color)
        case .noFrames:
            BrutalistStatusChip("No sound", tint: semantic.warning.color)
        case .error:
            BrutalistStatusChip("Problem", tint: semantic.warning.color)
        case .idle:
            EmptyView()
        }
        if let notice = model.engineNotice {
            BrutalistStatusChip(notice, tint: semantic.info.color)
        }
    }

    private func turnRow(_ turn: MeetingLiveModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Self.timeLabel(turn.t))
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
                if turn.isYou {
                    Rectangle().fill(palette.primary.color).frame(width: 6, height: 6)
                }
                Text(model.displayName(for: turn.speakerID))
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(turn.isYou ? palette.fg.color : palette.fgSidebar.color)
                    .help(turn.isYou ? "" : "Right-click to rename this speaker")
                    .contextMenu {
                        if !turn.isYou {
                            Button("Rename speaker…") { startRename(turn.speakerID) }
                        }
                    }
            }
            Text(turn.text)
                .font(BrutalistTypography.transcriptBody)
                .foregroundStyle(palette.fg.color)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activePartials: [(speakerID: String, text: String)] {
        model.partials
            .filter { !$0.value.isEmpty }
            .map { (speakerID: $0.key, text: $0.value) }
            .sorted { $0.speakerID < $1.speakerID }
    }

    private func partialRow(_ partial: (speakerID: String, text: String)) -> some View {
        HStack(spacing: 8) {
            Text(model.displayName(for: partial.speakerID))
                .font(BrutalistTypography.captionEmphasis)
                .foregroundStyle(palette.fgMuted.color)
            Text(partial.text)
                .font(BrutalistTypography.transcriptBody)
                .italic()
                .foregroundStyle(palette.fgMuted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: My Notes

    private var notesColumn: some View {
        VStack(spacing: 0) {
            columnHeader("My notes") {
                BrutalistStatusChip("Auto-saved", tint: palette.fgMuted.color)
            }
            TextEditor(text: $model.notes)
                .font(BrutalistTypography.mono12)
                .foregroundStyle(palette.fg.color)
                .scrollContentBackground(.hidden)
                .background(palette.background.color)
                .padding(8)
                .onChange(of: model.notes) { _, _ in scheduleNotesSave() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = Task { [model] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            await model.persistNotes()
        }
    }

    // MARK: AI Summary

    private var summaryColumn: some View {
        VStack(spacing: 0) {
            summaryHeader
            categorizationBanner
            if showSteer { steerField }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.liveSummary.isEmpty {
                        Text(summaryPlaceholder)
                            .font(BrutalistTypography.body)
                            .foregroundStyle(palette.fgMuted.color)
                            .padding(.top, 24)
                    } else {
                        BrutalistMarkdownView(markdown: model.liveSummary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Post-finalize auto-categorization prompt (BAS-9): confirms a high-confidence
    /// auto-file or offers the top candidates as one-tap project buttons.
    @ViewBuilder
    private var categorizationBanner: some View {
        if let categorization = model.categorization {
            VStack(alignment: .leading, spacing: BrutalistMetrics.space2) {
                BrutalistBanner(
                    kind: categorization.isAutoFiled ? .success : .info,
                    title: categorization.headline,
                    detail: categorization.candidates.isEmpty
                        ? nil
                        : (categorization.isAutoFiled ? "Change project" : "File this meeting"),
                    actionTitle: "Dismiss",
                    action: { model.dismissCategorization() }
                )
                if !categorization.candidates.isEmpty {
                    HStack(spacing: BrutalistMetrics.space1) {
                        ForEach(categorization.candidates) { candidate in
                            BrutalistButton(candidate.name, kind: .ghost, size: .compact) {
                                Task { await model.chooseProject(candidate.id) }
                            }
                            .help("File in \(candidate.name)")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Text("AI summary")
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            Spacer()
            if model.canRegenerate {
                Button {
                    showSteer.toggle()
                } label: {
                    Text(model.isRegenerating ? "Regenerating…" : "Regenerate")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                }
                .buttonStyle(.plain)
                .disabled(model.isRegenerating)
                .help("Regenerate the summary")
            }
            summaryStatus
        }
        .padding(.horizontal, 14)
        .frame(height: kColumnTopStripHeight)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var summaryStatus: some View {
        let semantic = BrutalistPalette.semantic(scheme)
        switch model.summaryState {
        case .none:
            EmptyView()
        case .streaming:
            BrutalistStatusChip("Writing…", tint: semantic.info.color)
        case .final:
            BrutalistStatusChip("Done", tint: semantic.success.color)
        }
    }

    /// Revealed by the Regenerate button: an optional one-off emphasis for this
    /// version (e.g. "focus on objections").
    ///
    /// Empty = the base summary prompt.
    private var steerField: some View {
        HStack(spacing: 8) {
            TextField("Optional: what to emphasise — e.g. objections, decisions, next steps", text: $steerText)
                .textFieldStyle(.plain)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fg.color)
                .onSubmit { runRegenerate() }
            BrutalistButton("Go", kind: .ghost, size: .compact) { runRegenerate() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private func runRegenerate() {
        let steer = steerText
        showSteer = false
        steerText = ""
        Task { await model.regenerate(steer: steer) }
    }

    private var summaryPlaceholder: String {
        model.summaryState == .none
            ? "A rolling summary appears here during the meeting; the full structured note is generated when you stop."
            : "Summarising…"
    }

    // MARK: Shared

    private func columnHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(BrutalistTypography.labelEmphasis)
                .foregroundStyle(palette.fg.color)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: kColumnTopStripHeight)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private static func timeLabel(_ t: Double) -> String {
        let total = max(0, Int(t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
