import SharedCore
import SwiftUI

// Pin bare `LibraryItem` to SharedCore's type — `SwiftUI.LibraryItem` otherwise
// makes the name ambiguous in this SwiftUI file.
import struct SharedCore.LibraryItem

/// The Library search + cross-meeting Q&A surface (design §9 / mockup 08).
///
/// One search bar, two auto-detected modes — Keyword (FTS5 over transcripts +
/// notes, ranked) and Q&A (hybrid retrieval → cited LLM answer). Scope pills
/// (all projects / a project / last 90 days), grouped keyword results, and a
/// cited answer whose sources click through to `meeting @ timestamp`.
@MainActor
public struct LibrarySearchView: View {
    @Environment(\.brutalistPalette) private var palette
    @Bindable var model: LibrarySearchModel
    @FocusState private var queryFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    public init(model: LibrarySearchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            scopeRow
            // Type-filter chips only make sense for keyword results (Q&A composes
            // one answer across everything), so show them in keyword mode only.
            if model.effectiveMode == .keyword { sourceChips }
            Rectangle().fill(palette.borderSoft.color).frame(height: 1)
            resultsArea
        }
        .task {
            await model.loadProjectsIfNeeded()
            await model.refreshEmbeddingAvailability()
            // Index any dictations / files / voice memos captured since launch so
            // keyword search surfaces them (cheap, signature-gated).
            await model.reconcileEntries?()
        }
        .onAppear { queryFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenSearch)) { _ in
            queryFocused = true
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Text(modePrefixGlyph)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.primary.color)
                .frame(width: 14)
            TextField("Search your library, or ask a question…", text: $model.query)
                .textFieldStyle(.plain)
                .font(BrutalistTypography.uiBody)
                .foregroundStyle(palette.fg.color)
                .focused($queryFocused)
                .onChange(of: model.query) { _, _ in queryEdited() }
                .onSubmit { runNow() }
            modeToggle
        }
        .padding(BrutalistMetrics.space3)
        .background(palette.bgTertiary.color)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: 1),
            alignment: .bottom
        )
    }

    /// `?` while in Q&A, `/` while in keyword — echoes the auto-detected mode.
    private var modePrefixGlyph: String {
        model.effectiveMode == .qa ? "?" : "/"
    }

    private var modeToggle: some View {
        HStack(spacing: 6) {
            modeSegment("Keyword", mode: .keyword)
            modeSegment("Q&A", mode: .qa)
        }
    }

    private func modeSegment(_ label: String, mode: LibrarySearchModel.Mode) -> some View {
        BrutalistChip(label, active: model.effectiveMode == mode)
            .contentShape(Rectangle())
            .onTapGesture {
                model.manualMode = mode
                runNow()
            }
    }

    // MARK: Scope row

    private var scopeRow: some View {
        HStack(spacing: 8) {
            scopePill("All projects", active: model.selectedProjectId == nil) {
                model.selectProject(nil)
                scopeChanged()
            }
            projectMenu
            scopePill("Last 90 days", active: model.last90Days) {
                model.last90Days.toggle()
                scopeChanged()
            }
            Spacer()
            Text(
                model.effectiveMode == .qa
                    ? "Q&A · a cited answer across your meetings and playbooks"
                    : "Keyword · meetings, dictations, files and memos"
            )
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, BrutalistMetrics.space3)
        .padding(.vertical, 8)
    }

    private var projectMenu: some View {
        Menu {
            Button("All projects") {
                model.selectProject(nil)
                scopeChanged()
            }
            if !model.projects.isEmpty { Divider() }
            ForEach(model.projects) { project in
                Button(project.name) {
                    model.selectProject(project.id)
                    scopeChanged()
                }
            }
        } label: {
            BrutalistChip(
                model.selectedProjectName ?? "Project",
                active: model.selectedProjectId != nil
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func scopePill(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { BrutalistChip(text, active: active) }
            .buttonStyle(.plain)
    }

    // MARK: Type-filter chips (keyword mode)

    private static let chipSources: [LibraryItem.Source] = [.meeting, .dictation, .voiceMemo, .file]

    private var sourceChips: some View {
        HStack(spacing: 8) {
            ForEach(Self.chipSources, id: \.self) { source in
                sourceChip(source)
            }
            Spacer()
        }
        .padding(.horizontal, BrutalistMetrics.space3)
        .padding(.bottom, 8)
    }

    private func sourceChip(_ source: LibraryItem.Source) -> some View {
        let active = model.selectedSources.contains(source)
        return BrutalistChip(Self.chipLabel(source), active: active)
            .contentShape(Rectangle())
            .onTapGesture {
                model.toggleSource(source)
                scopeChanged()
            }
    }

    private static func chipLabel(_ source: LibraryItem.Source) -> String {
        switch source {
        case .meeting: return "Meetings"
        case .dictation: return "Dictation"
        case .voiceMemo: return "Voice memos"
        case .file: return "Files"
        default: return ""
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                embeddingBanner
                if model.isSearching {
                    statusBlock(title: "Searching…", detail: nil)
                } else if model.errorMessage != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        statusBlock(
                            title: "Couldn't complete the search",
                            detail: "Something went wrong. Check your model settings and try again."
                        )
                        BrutalistButton(
                            "Open model settings",
                            kind: .ghost,
                            size: .compact,
                            systemImage: "gearshape"
                        ) { model.openSettings?() }
                    }
                } else if model.normalizedQuery.isEmpty {
                    emptyState
                } else if model.effectiveMode == .qa {
                    if let answer = model.answer {
                        qaAnswer(answer)
                    } else {
                        statusBlock(
                            title: "Press Return to ask",
                            detail: "Q&A composes a cited answer across your meetings and playbooks.")
                    }
                } else {
                    keywordResults
                }
            }
            .padding(BrutalistMetrics.space3)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search across every captured surface.")
                .font(BrutalistTypography.uiBody)
                .foregroundStyle(palette.fg.color)
            Text(
                "Type words to search; end with “?” for a cited answer across your meetings and playbooks · ⌘K opens this anywhere."
            )
            .font(BrutalistTypography.caption)
            .foregroundStyle(palette.fgMuted.color)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func statusBlock(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrutalistTypography.uiBody)
                .foregroundStyle(palette.fg.color)
            if let detail {
                Text(detail)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fgMuted.color)
                    .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }

    // MARK: Embedding-availability banner

    /// Visible, actionable warning when the model smart search and Q&A depend on
    /// isn't available — so it's never a silent degradation.
    @ViewBuilder
    private var embeddingBanner: some View {
        if let availability = model.embeddingAvailability, availability.needsAttention {
            BrutalistBanner(
                kind: .warning,
                title: bannerTitle(availability),
                detail: bannerDetail(availability),
                actionTitle: "Open settings"
            ) { model.openSettings?() }
            .padding(.bottom, 14)
        }
    }

    private func bannerTitle(_ availability: EmbeddingAvailability) -> String {
        switch availability {
        case .modelMissing: return "Smart search is off — its model isn’t installed"
        case .ollamaUnreachable: return "Smart search is off — Ollama isn’t running"
        case .ok, .notApplicable: return ""
        }
    }

    private func bannerDetail(_ availability: EmbeddingAvailability) -> String {
        switch availability {
        case .modelMissing:
            return
                "Q&A and meeting search fall back to plain keyword matching, and new meetings aren’t fully indexed. Install the model in settings to turn smart search back on."
        case .ollamaUnreachable:
            return "Start Ollama, or choose a cloud provider in settings, to turn smart search back on."
        case .ok, .notApplicable:
            return ""
        }
    }

    // MARK: Keyword results

    @ViewBuilder
    private var keywordResults: some View {
        let groups = model.groupedKeywordHits
        if groups.isEmpty {
            statusBlock(title: "No matches", detail: "Nothing in your library matched “\(model.normalizedQuery)”.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(model.keywordHits.count) matches · \(groups.count) result\(groups.count == 1 ? "" : "s")")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .padding(.bottom, 4)
                ForEach(groups) { group in keywordGroupRow(group) }
            }
        }
    }

    private func keywordGroupRow(_ group: KeywordGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BrutalistChip(Self.sourceBadge(group.source), active: true)
                Text(group.title)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Spacer()
                Text(whenLabel(group.startedAt))
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
            }
            ForEach(Array(group.hits.prefix(3))) { hit in
                HStack(alignment: .top, spacing: 8) {
                    if let ts = hit.timestamp {
                        Text(TranscriptChunker.timeLabel(ts))
                            .font(BrutalistTypography.mono10)
                            .foregroundStyle(palette.fgMuted.color)
                            .frame(width: 44, alignment: .leading)
                    }
                    Text(highlighted(hit.snippet))
                        .font(BrutalistTypography.uiLabel)
                        .foregroundStyle(palette.fgSidebar.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                Text("\(group.hitCount) hit\(group.hitCount == 1 ? "" : "s")")
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                BrutalistButton("Open", kind: .ghost, size: .compact) { openGroup(group) }
            }
        }
        .padding(BrutalistMetrics.space3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.bgCard.color)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { openGroup(group) }
        .padding(.bottom, 8)
    }

    /// Open a keyword group: meeting sub-sources deep-link to the meeting at the
    /// earliest matched offset; whole-item sources navigate to their section.
    private func openGroup(_ group: KeywordGroup) {
        switch group.source {
        case .meeting, .transcript, .notes:
            model.openMeeting?(group.id, group.firstTimestamp)
        default:
            model.openItem?(group.source, group.id, group.projectId)
        }
    }

    private static func sourceBadge(_ source: LibraryItem.Source) -> String {
        switch source {
        case .transcript: return "Transcript"
        case .notes: return "Notes"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        case .file: return "File"
        case .voiceMemo: return "Voice memo"
        case .playbook: return "Playbook"
        }
    }

    // MARK: Q&A answer

    private func qaAnswer(_ answer: QASearchPipeline.CitedAnswer) -> some View {
        // Show only the sources the answer ACTUALLY cited — not everything that was
        // retrieved into context — so a refusal shows none and a real answer shows
        // just its references.
        let cited = answer.citations.filter { answer.validation.citedIndices.contains($0.id) }
        let refusal = LibrarySearchModel.isLikelyRefusal(answer.answer)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Answer")
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
                Spacer()
                Text(answerMetaLabel(answer, citedCount: cited.count))
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
            }

            // Markdown answer (bullets / bold like the meeting summary) with
            // interactive [N] citations: hover → source preview card, click → open
            // (meeting @ timestamp, or the playbook source file).
            CitedAnswerView(answer: answer) { passage in handleCitationOpen(passage) }
                .frame(maxWidth: 720, alignment: .leading)

            // Only warn about sourcing when the model actually made claims — a
            // legitimate "the context doesn't cover this" needs no citations.
            if !refusal {
                if cited.isEmpty {
                    warningBadge("This answer cites no sources — treat it with caution.")
                } else if answer.validation.hasViolations {
                    warningBadge("Some statements may be unsourced — verify against the citations below.")
                }
            }

            if !cited.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Citations · \(cited.count) source\(cited.count == 1 ? "" : "s")")
                        .font(BrutalistTypography.caption)
                        .foregroundStyle(palette.fgMuted.color)
                    ForEach(cited) { citation in citationRow(citation) }
                }
            }
        }
    }

    private func warningBadge(_ text: String) -> some View {
        BrutalistBanner(kind: .warning, title: text)
            .frame(maxWidth: 720, alignment: .leading)
    }

    private func citationRow(_ citation: QASearchPipeline.Citation) -> some View {
        let passage = citation.passage
        return HStack(alignment: .top, spacing: 10) {
            Text("[\(citation.id)]")
                .font(BrutalistTypography.mono11)
                .foregroundStyle(palette.primary.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(citationSourceLabel(passage))
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
                Text(passage.text)
                    .font(BrutalistTypography.uiLabel)
                    .foregroundStyle(palette.fg.color)
                    .lineLimit(4)
                if let target = passage.openTarget {
                    BrutalistButton(
                        Self.openLabel(for: target),
                        kind: .ghost,
                        size: .compact,
                        systemImage: Self.openSymbol(for: target)
                    ) { handleCitationOpen(passage) }
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(palette.borderSoft.color).frame(height: 1), alignment: .bottom)
    }

    // MARK: Formatting helpers

    private func answerMetaLabel(_ answer: QASearchPipeline.CitedAnswer, citedCount: Int) -> String {
        var parts: [String] = []
        if !answer.model.isEmpty { parts.append(answer.model) }
        parts.append("\(citedCount) cited")
        return parts.joined(separator: " · ")
    }

    private func citationSourceLabel(_ passage: RetrievedPassage) -> String {
        ([passage.kindLabel] + passage.provenanceParts).joined(separator: " · ")
    }

    /// Dispatch a citation's open action: deep-link a meeting at its timestamp, or
    /// open the playbook source file.
    ///
    /// Shared by the inline chip + the row button so
    /// they stay in lock-step.
    private func handleCitationOpen(_ passage: RetrievedPassage) {
        switch passage.openTarget {
        case .meeting(let id, let ts): model.openMeeting?(id, ts)
        case .file(let path, let crumb): model.openSourceFile?(path, crumb)
        case nil: break
        }
    }

    private static func openLabel(for target: RetrievedPassage.OpenTarget) -> String {
        switch target {
        case .meeting: return "Open"
        case .file: return "Open file"
        }
    }

    private static func openSymbol(for target: RetrievedPassage.OpenTarget) -> String {
        switch target {
        case .meeting: return "arrow.up.forward"
        case .file: return "doc"
        }
    }

    /// Color the query's tokens inside a keyword snippet.
    private func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString(snippet)
        let terms = model.normalizedQuery
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        let lower = snippet.lowercased()
        for term in Set(terms) {
            var searchStart = lower.startIndex
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                if let attrRange = Range(range, in: result) {
                    result[attrRange].foregroundColor = palette.primary.color
                }
                searchStart = range.upperBound
            }
        }
        return result
    }

    private static let whenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h:mm a"
        return formatter
    }()

    private func whenLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.whenFormatter.string(from: date)
    }

    // MARK: Search triggering

    /// Query text changed: clear stale state, then debounce keyword search.
    ///
    /// Q&A waits for an explicit Return (LLM calls are expensive).
    private func queryEdited() {
        model.queryDidChange()
        debounceTask?.cancel()
        guard !model.normalizedQuery.isEmpty, model.effectiveMode == .keyword else { return }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await model.runSearch()
        }
    }

    /// Run immediately (Return key, mode toggle, scope change).
    private func runNow() {
        debounceTask?.cancel()
        Task {
            await model.runSearch()
            // A successful answer proves the model stack is reachable; only re-probe
            // embedding availability when Q&A errored or returned nothing.
            if model.effectiveMode == .qa,
                model.errorMessage != nil || (model.answer?.citations.isEmpty ?? true)
            {
                await model.refreshEmbeddingAvailability()
            }
        }
    }

    /// Scope changed: re-run the current query so results reflect the new scope.
    private func scopeChanged() {
        guard !model.normalizedQuery.isEmpty else { return }
        if model.effectiveMode == .keyword {
            runNow()
        } else if model.answer != nil {
            runNow()  // already answered → refresh under new scope
        }
    }
}
