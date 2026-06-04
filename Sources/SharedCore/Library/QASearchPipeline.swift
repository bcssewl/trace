import Foundation
import os

/// Cross-meeting Q&A (design §9.3). Hybrid retrieval over the unified chunk
/// store: a **dense** arm (cosine via `VectorSearch` over transcript + notes +
/// playbook embeddings) and a **lexical** arm (FTS5 over transcripts + notes),
/// fused by reciprocal-rank, de-duplicated by meeting-region, optionally
/// cross-encoder reranked, then handed to the LLM (`.libraryQA`) with a strict
/// cite-every-claim system prompt and post-generation citation enforcement.
///
/// The two arms are complementary: dense bridges vocabulary mismatch
/// (paraphrase recall), lexical nails exact terms / names / numbers. If the
/// dense arm is unavailable (e.g. the embedding model is offline) retrieval
/// degrades to lexical-only rather than failing the whole answer.
public actor QASearchPipeline {

    public struct CitedAnswer: Sendable, Hashable {
        public let answer: String
        public let citations: [Citation]
        public let validation: CitationEnforcer.Validation
        public let model: String
        public let provider: String
        public let usage: LLMUsage

        public init(
            answer: String,
            citations: [Citation],
            validation: CitationEnforcer.Validation,
            model: String,
            provider: String,
            usage: LLMUsage
        ) {
            self.answer = answer
            self.citations = citations
            self.validation = validation
            self.model = model
            self.provider = provider
            self.usage = usage
        }
    }

    public struct Citation: Sendable, Hashable, Identifiable {
        public let id: Int
        public let passage: RetrievedPassage
        public init(id: Int, passage: RetrievedPassage) {
            self.id = id
            self.passage = passage
        }
    }

    /// Default dense-arm cosine floor (BAS-30). nomic-embed-text similarities for
    /// genuinely-irrelevant chunks sit low; ~0.3 drops the obvious noise (`You: .`,
    /// `Yeah.`) without starving real paraphrase matches.
    ///
    /// Tunable in Advanced.
    public static let defaultDenseFloor: Float = 0.3

    private let embedder: EmbeddingClient
    private let vectorSearch: VectorSearch
    private let reranker: Reranker?
    private let router: ModelRouter
    private let lexical: LibraryStore?
    /// Minimum cosine for a dense hit to be considered (BAS-30). `≤ 0` disables.
    private let denseFloor: Float
    private let log = Loggers.library

    public init(
        embedder: EmbeddingClient,
        vectorSearch: VectorSearch,
        reranker: Reranker?,
        router: ModelRouter,
        lexical: LibraryStore? = nil,
        denseFloor: Float = QASearchPipeline.defaultDenseFloor
    ) {
        self.embedder = embedder
        self.vectorSearch = vectorSearch
        self.reranker = reranker
        self.router = router
        self.lexical = lexical
        self.denseFloor = denseFloor
    }

    /// Drop dense (cosine) hits below the relevance floor so genuinely-irrelevant
    /// chunks aren't fed to the LLM (BAS-30).
    ///
    /// A floor `≤ 0` disables the gate. The
    /// lexical arm is deliberately exempt — FTS hits matched the query's tokens,
    /// so they're relevant by construction.
    static func aboveDenseFloor(_ hits: [VectorSearch.Hit], floor: Float) -> [VectorSearch.Hit] {
        guard floor > 0 else { return hits }
        return hits.filter { $0.score >= floor }
    }

    public func ask(
        question: String,
        scope: LibrarySearchScope = LibrarySearchScope(),
        topRetrieve: Int = 20,
        topUse: Int = 8
    ) async throws -> CitedAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TraceError.configInvalid(field: "qa.question", reason: "empty question")
        }

        // Dense (cosine, scoped) + lexical (FTS5) arms run concurrently — the
        // local FTS query needn't wait on the dense embedding round-trip. Each arm
        // degrades to [] on failure (dense tolerates an unreachable embedder).
        async let denseResult = denseArm(trimmed, scope: scope, topRetrieve: topRetrieve)
        async let lexicalResult = lexicalArm(trimmed, scope: scope, topRetrieve: topRetrieve)
        let fused = Self.reciprocalRankFusion(dense: await denseResult, lexical: await lexicalResult)
        guard !fused.isEmpty else { return Self.emptyAnswer() }

        // Optional cross-encoder rerank, then take the top-K to cite.
        let selected = try await rerankIfPossible(question: trimmed, passages: fused, topUse: topUse)
        let citations = selected.enumerated().map { Citation(id: $0.offset + 1, passage: $0.element) }

        let request = buildRequest(question: trimmed, citations: citations)
        let response = try await router.generate(request)
        let validation = CitationEnforcer.validate(answer: response.text, contextChunkCount: citations.count)
        return CitedAnswer(
            answer: response.text,
            citations: citations,
            validation: validation,
            model: response.model,
            provider: response.provider,
            usage: response.usage
        )
    }

    // MARK: - Retrieval

    /// Dense (cosine) retrieval over the unified store, scoped.
    ///
    /// Degrades to [] if
    /// the embedding model is unreachable so Q&A can still answer from lexical.
    private func denseArm(_ query: String, scope: LibrarySearchScope, topRetrieve: Int) async -> [RetrievedPassage] {
        do {
            let queryVector = try await embedder.embedForQuery(text: query)
            let hits = try await vectorSearch.topK(
                query: queryVector, k: topRetrieve, where: Self.makeScopeFilter(scope))
            let kept = Self.aboveDenseFloor(hits, floor: denseFloor)
            return kept.map { RetrievedPassage(denseHit: $0.chunk, score: $0.score) }
        } catch {
            log.warning(
                "QA dense retrieval unavailable (\(error.localizedDescription, privacy: .public)); using lexical only")
            return []
        }
    }

    /// Lexical (FTS5) retrieval over transcripts + notes, scoped.
    private func lexicalArm(_ query: String, scope: LibrarySearchScope, topRetrieve: Int) async -> [RetrievedPassage] {
        guard let lexical else { return [] }
        let hits = (try? await lexical.searchKeyword(query: query, scope: scope, limit: topRetrieve)) ?? []
        return hits.map(Self.passage(fromKeyword:))
    }

    /// A predicate that scopes dense retrieval by project / recency / source.
    ///
    /// Playbook chunks are global reference material, so project + recency
    /// filters never exclude them. Returns nil when the scope is unconstrained
    /// (skip the per-chunk closure entirely).
    static func makeScopeFilter(_ scope: LibrarySearchScope) -> (@Sendable (KbChunk) -> Bool)? {
        let hasProject = (scope.projectIds?.isEmpty == false)
        let hasRecency = scope.lastNDays != nil
        let hasSources = !scope.sources.isEmpty
        guard hasProject || hasRecency || hasSources else { return nil }

        let projectIds = scope.projectIds
        let sources = scope.sources
        let cutoff = scope.cutoffDate

        return { chunk in
            let isMeeting = chunk.sourceKind != .playbook
            if isMeeting, let projectIds, !projectIds.isEmpty {
                guard let pid = chunk.projectId, projectIds.contains(pid) else { return false }
            }
            if isMeeting, let cutoff {
                guard let started = chunk.startedAt, started >= cutoff else { return false }
            }
            if !sources.isEmpty {
                guard Self.kindAllowed(chunk.sourceKind, sources: sources) else { return false }
            }
            return true
        }
    }

    static func kindAllowed(_ kind: KbChunk.SourceKind, sources: Set<LibraryItem.Source>) -> Bool {
        switch kind {
        case .transcript: return sources.contains(.transcript) || sources.contains(.meeting)
        case .notes: return sources.contains(.notes) || sources.contains(.meeting)
        case .summary: return sources.contains(.meeting) || sources.contains(.transcript)
        case .playbook: return sources.contains(.playbook)
        }
    }

    static func passage(fromKeyword hit: KeywordHit) -> RetrievedPassage {
        RetrievedPassage(
            id: "lex:\(hit.id)",
            kind: hit.source == .notes ? .notes : .transcript,
            text: hit.snippet,
            projectId: hit.projectId,
            meetingId: hit.itemId,
            title: hit.title,
            speaker: hit.speaker,
            tsSeconds: hit.timestamp,
            sourceFile: nil,
            breadcrumb: nil,
            score: 0,
            origin: .lexical
        )
    }

    /// Reciprocal-rank fusion of the two ranked arms.
    ///
    /// Each passage contributes
    /// `1 / (k + rank)` to its de-dupe key's score; the representative kept per
    /// key prefers the dense (richer, longer) passage over a lexical snippet.
    static func reciprocalRankFusion(
        dense: [RetrievedPassage], lexical: [RetrievedPassage], k: Double = 60
    ) -> [RetrievedPassage] {
        var scoreByKey: [String: Double] = [:]
        var repByKey: [String: RetrievedPassage] = [:]

        func ingest(_ list: [RetrievedPassage]) {
            for (rank, passage) in list.enumerated() {
                let key = passage.dedupeKey
                scoreByKey[key, default: 0] += 1.0 / (k + Double(rank + 1))
                if let existing = repByKey[key] {
                    if existing.origin == .lexical, passage.origin == .dense {
                        repByKey[key] = passage
                    }
                } else {
                    repByKey[key] = passage
                }
            }
        }
        ingest(dense)
        ingest(lexical)

        return
            scoreByKey
            .sorted { $0.value > $1.value }
            .compactMap { repByKey[$0.key] }
    }

    private func rerankIfPossible(
        question: String, passages: [RetrievedPassage], topUse: Int
    ) async throws -> [RetrievedPassage] {
        guard let reranker else { return Array(passages.prefix(topUse)) }
        let candidates = passages.map { Reranker.Candidate(chunkId: $0.id, text: $0.text) }
        let ranked = try await reranker.rerank(query: question, candidates: candidates)
        let byId = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reordered = ranked.compactMap { byId[$0.chunkId] }
        return reordered.isEmpty ? Array(passages.prefix(topUse)) : Array(reordered.prefix(topUse))
    }

    // MARK: - Generation

    private func buildRequest(question: String, citations: [Citation]) -> LLMRequest {
        var contextLines: [String] = []
        for citation in citations {
            contextLines.append("[\(citation.id)] \(Self.contextLabel(citation.passage))")
            contextLines.append(citation.passage.text)
            contextLines.append("")
        }
        let wrappedContext = AntiInjectionGuard.wrap(
            contextLines.joined(separator: "\n"), source: .ragChunk
        )
        let system = """
            You answer questions strictly from the supplied context chunks about the user's meetings and playbooks.
            Each chunk is labeled [N] in the order presented; cite the chunk(s) supporting each claim by appending the matching [N] marker inline.
            Do not invent facts not in the context. If the context does not answer the question, say so plainly.
            """
        let user = """
            Question: \(question)

            Context:
            \(wrappedContext)
            """
        return LLMRequest(
            messages: [
                LLMMessage(role: .system, content: system),
                LLMMessage(role: .user, content: user),
            ],
            taskClass: .libraryQA,
            temperature: 0.1
        )
    }

    /// Human-readable provenance label for a cited chunk in the assembled
    /// context — meeting title · speaker · timestamp, or a playbook breadcrumb.
    static func contextLabel(_ passage: RetrievedPassage) -> String {
        let parts = passage.provenanceParts
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return passage.kind == .playbook ? "Playbook" : "Meeting"
    }

    private static func emptyAnswer() -> CitedAnswer {
        CitedAnswer(
            answer:
                "No indexed meetings or playbooks matched this question. Try rephrasing, widening the scope, or indexing your meetings and playbooks first.",
            citations: [],
            validation: .empty,
            model: "",
            provider: "",
            usage: .zero
        )
    }
}
