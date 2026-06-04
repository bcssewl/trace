import Foundation
import Observation
import SharedCore

/// Backs the Library search surface (the ⌘K / Inbox content pane).
///
/// Mirrors the
/// `PlaybooksModel` / `MeetingLibraryModel` pattern: a `@MainActor @Observable`
/// view-model whose actual work is performed by closures the
/// `AppRuntimeCoordinator` wires in (it owns the database, router, and the
/// hybrid `QASearchPipeline`). The view binds to the observable state; mode
/// auto-detection and scope assembly are pure and live here so they're testable
/// without the backend.
@Observable
@MainActor
public final class LibrarySearchModel {

    public enum Mode: String, Sendable, CaseIterable {
        case keyword
        case qa
    }

    /// Result of a Q&A run — a cited answer, or a user-facing failure message.
    ///
    /// (A bespoke enum rather than `Result` because the failure is a plain
    /// `String`, which doesn't conform to `Error`.)
    public enum AskOutcome: Sendable {
        case success(QASearchPipeline.CitedAnswer)
        case failure(String)
    }

    // MARK: Input

    public var query: String = ""
    /// User's explicit mode override via the toggle; nil ⇒ auto-detect from input.
    public var manualMode: Mode?
    /// nil ⇒ all projects; otherwise scope to this project.
    public var selectedProjectId: String?
    public var last90Days: Bool = false
    /// Keyword-mode type-filter chips (design mockup 08 panel B): Meeting /
    /// Dictation / Voice memo / File.
    ///
    /// Empty = search every surface.
    public var selectedSources: Set<LibraryItem.Source> = []
    /// Projects available for the scope picker (loaded lazily).
    public var projects: [ProjectInfo] = []

    // MARK: Output

    public var keywordHits: [KeywordHit] = []
    public var answer: QASearchPipeline.CitedAnswer?
    public var isSearching: Bool = false
    public var errorMessage: String?
    /// The query string the currently-displayed results correspond to.
    public var lastRunQuery: String = ""
    /// Availability of the embedding model the semantic features depend on (Q&A
    /// dense retrieval + meeting indexing). nil until first checked; surfaced as a
    /// banner so a missing model is visible, not a silent fallback.
    public var embeddingAvailability: EmbeddingAvailability?

    // MARK: Wired by the coordinator

    public var searchKeyword: (@MainActor (_ query: String, _ scope: LibrarySearchScope) async -> [KeywordHit])?
    public var ask: (@MainActor (_ question: String, _ scope: LibrarySearchScope) async -> AskOutcome)?
    public var loadProjects: (@MainActor () async -> [ProjectInfo])?
    /// Navigate to a meeting (optionally at a timestamp) — citation / hit click.
    public var openMeeting: (@MainActor (_ meetingId: String, _ timestamp: Double?) -> Void)?
    /// Open a non-meeting keyword hit (dictation / file / voice memo) by
    /// navigating to the section that shows it.
    ///
    /// Meeting hits use `openMeeting`.
    public var openItem: (@MainActor (_ source: LibraryItem.Source, _ itemId: String, _ projectId: String?) -> Void)?
    /// Open a playbook source file (a playbook citation's open action). `path` is
    /// the chunk's relative `source_file`; the coordinator resolves it to an
    /// absolute URL and hands it to NSWorkspace. `breadcrumb` is the cited section
    /// for context (NSWorkspace can't seek to a heading, so it's advisory).
    public var openSourceFile: (@MainActor (_ path: String, _ breadcrumb: String?) -> Void)?
    /// Open Settings (lands on the LLM Router tab) — used by the Q&A error CTA.
    public var openSettings: (@MainActor () -> Void)?
    /// Probe whether the embedding model is installed + reachable.
    public var checkEmbeddingAvailability: (@MainActor () async -> EmbeddingAvailability)?
    /// Refresh the keyword index of dictations / files / voice memos.
    ///
    /// Cheap
    /// (signature-gated), so the view calls it when the search surface appears to
    /// pick up anything captured since launch.
    public var reconcileEntries: (@MainActor () async -> Void)?

    public init() {}

    // MARK: Derived

    /// Effective mode: the user's override if set, else auto-detected from input.
    public var effectiveMode: Mode {
        manualMode ?? Self.autodetectMode(query)
    }

    public var selectedProjectName: String? {
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }?.name
    }

    public var scope: LibrarySearchScope {
        LibrarySearchScope(
            projectIds: selectedProjectId.map { [$0] },
            lastNDays: last90Days ? 90 : nil,
            sources: []
        )
    }

    /// Scope for keyword search: the same project / recency as `scope`, but with
    /// the type-filter chips applied — or all four item surfaces when none are
    /// selected.
    ///
    /// Kept separate from `scope` so Q&A (which passes `scope`, whose
    /// empty source set means meetings only) never inherits the keyword chips.
    public var keywordScope: LibrarySearchScope {
        // Same project / recency as `scope`; only the source set differs.
        var keyword = scope
        keyword.sources =
            selectedSources.isEmpty
            ? [.meeting, .dictation, .voiceMemo, .file]
            : selectedSources
        return keyword
    }

    /// The query with the keyword-forcing `/` prefix stripped.
    public var normalizedQuery: String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("/") {
            q.removeFirst()
            q = q.trimmingCharacters(in: .whitespaces)
        }
        return q
    }

    /// Keyword hits grouped by their owning item (meeting / dictation / file /
    /// voice memo), preserving relevance order, so the UI can render one row per
    /// item with a hit count + the top snippets.
    public var groupedKeywordHits: [KeywordGroup] {
        var order: [String] = []
        var byItem: [String: [KeywordHit]] = [:]
        for hit in keywordHits {
            if byItem[hit.itemId] == nil { order.append(hit.itemId) }
            byItem[hit.itemId, default: []].append(hit)
        }
        return order.compactMap { itemId in
            guard let hits = byItem[itemId], let first = hits.first else { return nil }
            return KeywordGroup(
                id: itemId, source: first.source, title: first.title, projectId: first.projectId,
                startedAt: first.startedAt, hits: hits
            )
        }
    }

    // MARK: Actions

    /// Run the search for the current query/mode/scope.
    ///
    /// Q&A is invoked on submit;
    /// keyword can be invoked on a debounced change. Empty input clears results.
    public func runSearch() async {
        let q = normalizedQuery
        guard !q.isEmpty else {
            clearResults()
            return
        }
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }

        switch effectiveMode {
        case .keyword:
            answer = nil
            if let searchKeyword {
                keywordHits = await searchKeyword(q, keywordScope)
            }
        case .qa:
            keywordHits = []
            if let ask {
                switch await ask(q, scope) {
                case .success(let cited): answer = cited
                case .failure(let message):
                    errorMessage = message
                    answer = nil
                }
            }
        }
        lastRunQuery = query
    }

    public func clearResults() {
        keywordHits = []
        answer = nil
        errorMessage = nil
        lastRunQuery = ""
    }

    /// React to the query field changing: clearing it resets a sticky manual mode
    /// override (so auto-detection resumes for the next query) and the results.
    public func queryDidChange() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manualMode = nil
            clearResults()
        }
    }

    public func selectProject(_ id: String?) {
        selectedProjectId = id
    }

    /// Toggle a keyword type-filter chip on/off.
    public func toggleSource(_ source: LibraryItem.Source) {
        if selectedSources.contains(source) {
            selectedSources.remove(source)
        } else {
            selectedSources.insert(source)
        }
    }

    public func loadProjectsIfNeeded() async {
        guard projects.isEmpty, let loadProjects else { return }
        projects = await loadProjects()
    }

    public func refreshEmbeddingAvailability() async {
        guard let checkEmbeddingAvailability else { return }
        embeddingAvailability = await checkEmbeddingAvailability()
    }

    // MARK: Pure mode auto-detection (design §9.2)

    /// Interrogative-leading or `?`-terminated input ⇒ Q&A; a `/` prefix or a
    /// plain fragment ⇒ keyword.
    ///
    /// Matches the mockup's auto-detect rules.
    public static func autodetectMode(_ raw: String) -> Mode {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .keyword }
        if q.hasPrefix("/") { return .keyword }
        if q.hasSuffix("?") { return .qa }
        let lower = q.lowercased()
        for phrase in ["tell me", "summarize", "summarise"] where lower.hasPrefix(phrase) {
            return .qa
        }
        let interrogatives: Set<String> = [
            "what", "when", "who", "whom", "whose", "how", "why", "which",
            "should", "is", "are", "was", "were", "can", "could", "do", "does",
            "did", "will", "would", "has", "have",
        ]
        if let firstWord = lower.split(whereSeparator: { !$0.isLetter }).first.map(String.init),
            interrogatives.contains(firstWord)
        {
            return .qa
        }
        return .keyword
    }

    /// Heuristic: did the model decline to answer from the context?
    ///
    /// Such answers
    /// legitimately carry no citations, so the UI shouldn't flag them as
    /// "unsourced" or list the chunks it merely looked at as if they were used.
    public static func isLikelyRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "context does not", "context doesn't", "does not provide", "doesn't provide",
            "no relevant", "couldn't find", "could not find", "don't have", "do not have",
            "can't answer", "cannot answer", "can't assist", "cannot assist",
            "not enough information", "no information", "no indexed",
        ]
        return markers.contains { lower.contains($0) }
    }
}

/// Keyword hits for one item (meeting / dictation / file / voice memo), grouped
/// for display.
public struct KeywordGroup: Identifiable, Sendable, Hashable {
    public let id: String  // itemId
    /// The item's source kind — drives the row badge + the open action.
    public let source: LibraryItem.Source
    public let title: String
    public let projectId: String?
    public let startedAt: Date?
    public let hits: [KeywordHit]

    public var hitCount: Int { hits.count }
    /// Earliest cited offset in the meeting — the deep-link target for "Open".
    public var firstTimestamp: Double? { hits.compactMap(\.timestamp).min() }

    public init(
        id: String, source: LibraryItem.Source, title: String,
        projectId: String?, startedAt: Date?, hits: [KeywordHit]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.projectId = projectId
        self.startedAt = startedAt
        self.hits = hits
    }
}
