import CoachModule
import Foundation
import SharedCore

// Offline scenario benchmark for the meeting coach (BAS — coach rebuild).
//
// Replays scripted meetings through the REAL `CoachListener` against the REAL
// routed cloud model (OpenRouter, the app's default coach route) and reports
// what the coach did versus what the scenario expected. The listener's
// injected `now:` clock is driven from the scenario's `t` values, so an
// hour-long script replays in the wall time of its model calls only.
//
// Usage:  swift run TraceReplay coach-bench <scenarios-dir> [--only <name>]
//
// The OpenRouter key is read from the app's Keychain item (service
// "app.trace", account "openrouter"), with an env-var fallback
// (TRACE_OPENROUTER_KEY). Exit 2 when neither yields a key.

// MARK: - Scenario schema

struct BenchScenario: Decodable {
    let name: String
    let description: String
    let utterances: [BenchUtterance]
    let kbDocs: [BenchKbDoc]?
    let manualAsks: [BenchManualAsk]?
    let expect: [BenchExpectation]
}

struct BenchUtterance: Decodable {
    let t: Double
    let speaker: String
    let text: String
}

struct BenchKbDoc: Decodable {
    let title: String
    let content: String
}

struct BenchManualAsk: Decodable {
    let t: Double
    let intent: String
}

enum BenchExpectation: Decodable {
    case silenceThroughout
    case cardCountMax(Int)
    case answerContaining([String])
    case cardInLanguage(language: String, keywords: [String])
    case recallWithGrounding([String])
    case noDuplicateCards
    case manualAlwaysAnswers

    private enum CodingKeys: String, CodingKey {
        case type, max, keywords, language
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "silence_throughout":
            self = .silenceThroughout
        case "card_count_max":
            self = .cardCountMax(try c.decode(Int.self, forKey: .max))
        case "answer_containing":
            self = .answerContaining(try c.decode([String].self, forKey: .keywords))
        case "card_in_language":
            self = .cardInLanguage(
                language: try c.decode(String.self, forKey: .language),
                keywords: try c.decode([String].self, forKey: .keywords)
            )
        case "recall_with_grounding":
            self = .recallWithGrounding(try c.decode([String].self, forKey: .keywords))
        case "no_duplicate_cards":
            self = .noDuplicateCards
        case "manual_always_answers":
            self = .manualAlwaysAnswers
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown expectation type \"\(type)\"")
        }
    }

    var label: String {
        switch self {
        case .silenceThroughout: return "silence_throughout"
        case .cardCountMax(let n): return "card_count_max \(n)"
        case .answerContaining(let k): return "answer_containing \(k)"
        case .cardInLanguage(let lang, let k): return "card_in_language \"\(lang)\" \(k)"
        case .recallWithGrounding(let k): return "recall_with_grounding \(k)"
        case .noDuplicateCards: return "no_duplicate_cards"
        case .manualAlwaysAnswers: return "manual_always_answers"
        }
    }
}

// MARK: - Virtual clock

/// Thread-safe virtual clock the listener's injected `now:` reads. The driver
/// advances it second by second through the scenario's timeline; it freezes
/// while a model call is in flight (the driver waits for quiescence).
final class BenchClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        self.start = start
        self.current = start
    }

    func set(seconds: Int) {
        lock.lock()
        current = start.addingTimeInterval(Double(seconds))
        lock.unlock()
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func offsetSeconds() -> Int {
        Int(now().timeIntervalSince(start).rounded())
    }
}

// MARK: - Timeline log

enum BenchTimelineKind {
    case utterance(speaker: String, text: String)
    case modelCall(latencyMs: Int, sentChars: Int, replyText: String, directed: Bool, searchRound: Bool, failure: String?)
    case surfaced(CoachCard)
    case withheld(CoachCard, reason: CoachWithholdReason)
    case manualAsk(intent: String)
    case health(String)
    case harnessNote(String)
}

struct BenchTimelineEntry {
    let t: Int
    let kind: BenchTimelineKind
}

/// Append-only, lock-protected timeline shared by the driver, the router
/// wrapper, the listener's event callback, and the health subscriber.
final class BenchTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [BenchTimelineEntry] = []

    func add(t: Int, _ kind: BenchTimelineKind) {
        lock.lock()
        entries.append(BenchTimelineEntry(t: t, kind: kind))
        lock.unlock()
    }

    func snapshot() -> [BenchTimelineEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

// MARK: - Router wrapper (records every model call, passes through to the real route)

struct BenchRouterFacade: ModelRoutingFacade {
    let inner: ModelRouter
    let clock: BenchClock
    let timeline: BenchTimeline

    func stream(_ request: LLMRequest, routeOverride: LLMRoute?) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let virtualT = clock.offsetSeconds()
                let sentChars = request.messages.reduce(0) { $0 + $1.content.count }
                let directed = request.messages.first?.content.contains("DIRECTED REQUEST") ?? false
                let searchRound = request.messages.last?.content.hasPrefix("SEARCH RESULTS") ?? false
                let wallStart = Date()
                var text = ""
                do {
                    for try await delta in inner.stream(request, routeOverride: routeOverride) {
                        text += delta.textIncrement
                        continuation.yield(delta)
                        if delta.isFinal { break }
                    }
                    let ms = Int(Date().timeIntervalSince(wallStart) * 1000)
                    timeline.add(
                        t: virtualT,
                        .modelCall(
                            latencyMs: ms, sentChars: sentChars, replyText: text,
                            directed: directed, searchRound: searchRound, failure: nil))
                    continuation.finish()
                } catch {
                    let ms = Int(Date().timeIntervalSince(wallStart) * 1000)
                    timeline.add(
                        t: virtualT,
                        .modelCall(
                            latencyMs: ms, sentChars: sentChars, replyText: text,
                            directed: directed, searchRound: searchRound, failure: String(describing: error)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Retrieval stub (used ONLY when the embedding model is unreachable)

/// Empty retriever for scenarios without a knowledge base when the embedding
/// model is down. Its use is reported loudly — never a silent substitution.
struct BenchEmptyRetriever: CoachRetrieving {
    func setProjectScope(_ projectID: String?) async {}
    func retrieve(query: String, k: Int) async throws -> [VectorSearch.Hit] { [] }
}

// MARK: - Per-scenario result

struct BenchCheckOutcome {
    let virtualT: Int
    let latencyMs: Int
    let finalDecision: String
    let spoke: Bool
    let silent: Bool
    let unusable: Bool
    let failed: Bool
}

struct BenchScenarioRun {
    let scenario: BenchScenario
    var skippedReason: String?
    var timeline: [BenchTimelineEntry] = []
    var verdicts: [(label: String, pass: Bool, detail: String)] = []
    var autoCards: [CoachCard] = []
    var manualCards: [CoachCard] = []
    var withheldBudget = 0
    var withheldSpacing = 0
    var withheldDuplicate = 0
    var withheldRecall = 0

    var withheldTotal: Int { withheldBudget + withheldSpacing + withheldDuplicate + withheldRecall }
    var autoChecks: [BenchCheckOutcome] = []
    var modelCallCount = 0
    var searchRounds = 0
    var meanLatencyMs = 0
    var maxLatencyMs = 0
    var estTokens = 0
    var harnessError: String?
}

// MARK: - Bench

enum CoachBench {

    static let benchKeychainService = "app.trace.coachbench"
    static let openRouterAccount = "openrouter"

    static func run(arguments: [String]) async -> Int32 {
        var scenariosDir: String?
        var only: String?
        // Optional OpenRouter model override (e.g. "google/gemini-3.5-flash") so
        // candidate coach models can be benchmarked on identical scenarios.
        // Empty = the catalogue default.
        var modelOverride = ""
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--only", index + 1 < arguments.count {
                only = arguments[index + 1]
                index += 2
            } else if arg == "--model", index + 1 < arguments.count {
                modelOverride = arguments[index + 1]
                index += 2
            } else if scenariosDir == nil {
                scenariosDir = arg
                index += 1
            } else {
                err("coach-bench: unexpected argument \"\(arg)\"")
                return 2
            }
        }
        guard let scenariosDir else {
            err("usage: trace-replay coach-bench <scenarios-dir> [--only <name>] [--model <openrouter-id>]")
            return 2
        }

        // Load scenarios.
        let dirURL = URL(fileURLWithPath: scenariosDir)
        var scenarios: [BenchScenario] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    scenarios.append(try JSONDecoder().decode(BenchScenario.self, from: data))
                } catch {
                    err("coach-bench: failed to decode \(file.lastPathComponent): \(error)")
                    return 2
                }
            }
        } catch {
            err("coach-bench: cannot read scenarios directory \(scenariosDir): \(error)")
            return 2
        }
        if let only {
            scenarios = scenarios.filter { $0.name == only }
            guard !scenarios.isEmpty else {
                err("coach-bench: no scenario named \"\(only)\"")
                return 2
            }
        }
        guard !scenarios.isEmpty else {
            err("coach-bench: no scenario JSON files in \(scenariosDir)")
            return 2
        }

        // Resolve the OpenRouter key: the app's Keychain item first (this may
        // raise a macOS keychain permission dialog), then the env var.
        guard let keyOrigin = resolveOpenRouterKey() else {
            err(
                """
                coach-bench: no OpenRouter key found.
                Looked in the Keychain (service "app.trace", account "openrouter") and the
                TRACE_OPENROUTER_KEY environment variable. To run without Keychain access:
                  TRACE_OPENROUTER_KEY=sk-or-… swift run TraceReplay coach-bench \(scenariosDir)
                """)
            return 2
        }
        err("[bench] OpenRouter key resolved from \(keyOrigin)")

        // Build the router the way the app's factory does, with the OpenAI-compat
        // provider reading the bench's own Keychain copy of the key (so repeated
        // per-call reads never re-prompt against the app's item).
        let router = await makeRouter()
        await router.setRoute(ModelProvider.openRouter.route(model: modelOverride), for: .coachCardContent)
        let coachRoute = (try? await router.route(forLLM: .coachCardContent))
        err(
            "[bench] coach route: \(coachRoute?.provider.rawValue ?? "?") model=\(coachRoute?.model ?? "?") via \(coachRoute?.baseURL?.absoluteString ?? "?")"
        )

        // The app's configured embedding route (Settings default: local Ollama,
        // nomic-embed-text). Probed once; recall scenarios are skipped loudly if
        // the model is unreachable — never faked.
        let embedConfig = EmbeddingConfig(
            provider: "ollama",
            baseURL: URL(string: "http://localhost:11434"),
            model: "nomic-embed-text",
            normalization: .unitL2
        )
        let embedAvailability = await EmbeddingAvailabilityChecker().check(config: embedConfig)
        let embeddingsOK = embedAvailability.isOK
        err("[bench] embedding model (\(embedConfig.model) via Ollama): \(embeddingsOK ? "available" : "UNAVAILABLE — \(embedAvailability)")")

        var runs: [BenchScenarioRun] = []
        for scenario in scenarios {
            err("[bench] running scenario \(scenario.name)…")
            let run = await runScenario(
                scenario, router: router, embedConfig: embedConfig, embeddingsOK: embeddingsOK)
            runs.append(run)
            let passed = run.verdicts.filter(\.pass).count
            err(
                "[bench] \(scenario.name): \(run.skippedReason != nil ? "SKIPPED" : "\(passed)/\(run.verdicts.count) expectations passed")"
            )
        }

        let report = buildReport(runs: runs, coachRoute: coachRoute, embedConfig: embedConfig, embeddingsOK: embeddingsOK)
        print(report)
        let reportURL = dirURL.appendingPathComponent("REPORT.md")
        do {
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            err("[bench] report written to \(reportURL.path)")
        } catch {
            err("[bench] could not write report file: \(error)")
        }
        return 0
    }

    // MARK: Key plumbing

    /// Resolve the OpenRouter key and stash it under the bench's own Keychain
    /// service so the provider's per-call reads hit an item this binary owns.
    /// Returns a human-readable origin, or nil when no key is available.
    static func resolveOpenRouterKey() -> String? {
        let bench = KeychainSecrets(service: benchKeychainService)
        if let cached = (try? bench.load(account: openRouterAccount)) ?? nil, !cached.isEmpty {
            return "the bench Keychain cache (service \"\(benchKeychainService)\")"
        }
        if let appKey = (try? KeychainSecrets().load(account: openRouterAccount)) ?? nil, !appKey.isEmpty {
            try? bench.save(account: openRouterAccount, value: appKey)
            return "the app's Keychain item (service \"app.trace\")"
        }
        if let envKey = ProcessInfo.processInfo.environment["TRACE_OPENROUTER_KEY"],
            !envKey.trimmingCharacters(in: .whitespaces).isEmpty
        {
            try? bench.save(account: openRouterAccount, value: envKey)
            return "the TRACE_OPENROUTER_KEY environment variable"
        }
        return nil
    }

    /// Mirror of `ModelRouterFactory.makeDefaultRouter` (AppShell — not linkable
    /// from this CLI without dragging in AppKit), with the OpenAI-compat
    /// provider pointed at the bench's Keychain service.
    static func makeRouter() async -> ModelRouter {
        let router = ModelRouter()
        let appleFM: any LLMProvider = AppleFMProvider()
        let ollama = OllamaProvider()
        let openai = OpenAICompatProvider(keychain: KeychainSecrets(service: benchKeychainService))
        await router.register(provider: appleFM)
        await router.register(provider: ollama as any LLMProvider)
        await router.register(provider: ollama as any EmbeddingProvider)
        await router.register(provider: openai as any LLMProvider)
        await router.register(provider: openai as any EmbeddingProvider)
        await router.register(provider: AnthropicMessagesProvider())
        await router.register(provider: CodexSubscriptionProvider())
        return router
    }

    // MARK: Scenario runner

    static func runScenario(
        _ scenario: BenchScenario,
        router: ModelRouter,
        embedConfig: EmbeddingConfig,
        embeddingsOK: Bool
    ) async -> BenchScenarioRun {
        var run = BenchScenarioRun(scenario: scenario)
        let hasKb = !(scenario.kbDocs ?? []).isEmpty
        if hasKb && !embeddingsOK {
            run.skippedReason =
                "SKIPPED — this scenario needs the knowledge base, but the embedding model "
                + "(\(embedConfig.model) via Ollama) is unreachable. Start Ollama and re-run; the bench never fakes retrieval."
            return run
        }

        let timeline = BenchTimeline()
        let clock = BenchClock()

        // Knowledge base: a TEMP SQLite db + KbCache, embedded via the real route.
        var db: SqliteDatabase?
        var dbURL: URL?
        let retriever: any CoachRetrieving
        if embeddingsOK {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("coach-bench-\(UUID().uuidString).sqlite")
                let database = try await SqliteDatabase.open(at: url)
                try await AppSchema.bootstrap(database: database)
                db = database
                dbURL = url
                let cache = KbCache(db: database)
                if hasKb {
                    let indexEmbedder = EmbeddingClient(router: router, config: embedConfig, task: .embeddingsIndex)
                    let chunkCount = try await seedKnowledgeBase(
                        docs: scenario.kbDocs ?? [], cache: cache, embedder: indexEmbedder, config: embedConfig)
                    timeline.add(t: 0, .harnessNote("Knowledge base seeded: \(chunkCount) chunk(s) from \((scenario.kbDocs ?? []).count) document(s)."))
                }
                let vectorSearch = VectorSearch(cache: cache, config: embedConfig)
                retriever = CoachRetriever(
                    embedder: EmbeddingClient(router: router, config: embedConfig, task: .embeddingsLive),
                    vectorSearch: vectorSearch
                )
            } catch {
                run.harnessError = "knowledge-base setup failed: \(error)"
                run.skippedReason = "SKIPPED — harness error during knowledge-base setup: \(error)"
                return run
            }
        } else {
            retriever = BenchEmptyRetriever()
            timeline.add(
                t: 0,
                .harnessNote(
                    "Embedding model unreachable — retrieval stubbed to empty results for this no-KB scenario (reported, not silent)."
                ))
        }

        // The listener under test — real config defaults, real route, virtual clock.
        let config = CoachConfig()
        let listener = CoachListener(
            config: config,
            router: BenchRouterFacade(inner: router, clock: clock, timeline: timeline),
            retriever: retriever,
            now: { clock.now() },
            onEvent: { event in
                switch event {
                case .surfaced(let card):
                    timeline.add(t: clock.offsetSeconds(), .surfaced(card))
                case .withheld(let card, let reason):
                    timeline.add(t: clock.offsetSeconds(), .withheld(card, reason: reason))
                }
            }
        )

        let healthTask = Task {
            let stream = await listener.healthEvents()
            for await event in stream {
                switch event {
                case .stageUnavailable(let stage, let reason):
                    timeline.add(t: clock.offsetSeconds(), .health("stage \(stage.rawValue) UNAVAILABLE: \(reason)"))
                case .stageRecovered(let stage):
                    timeline.add(t: clock.offsetSeconds(), .health("stage \(stage.rawValue) recovered"))
                }
            }
        }

        await listener.beginMeeting(projectID: nil)

        // Merge utterances + manual asks into one timeline, sorted by t
        // (utterances before asks at the same second).
        enum SimItem {
            case utterance(BenchUtterance)
            case ask(BenchManualAsk)
            var t: Int {
                switch self {
                case .utterance(let u): return Int(u.t.rounded())
                case .ask(let a): return Int(a.t.rounded())
                }
            }
            var isAsk: Bool {
                if case .ask = self { return true }
                return false
            }
        }
        var items: [SimItem] =
            scenario.utterances.map { .utterance($0) } + (scenario.manualAsks ?? []).map { .ask($0) }
        items.sort { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return !lhs.isAsk && rhs.isAsk
        }

        var manualIDs: Set<UUID> = []
        let lastT = items.map(\.t).max() ?? 0
        let endT = lastT + config.effectiveCheckCadenceSeconds + 5

        var itemIndex = 0
        for t in 0...endT {
            clock.set(seconds: t)
            while itemIndex < items.count, items[itemIndex].t <= t {
                switch items[itemIndex] {
                case .utterance(let u):
                    timeline.add(t: t, .utterance(speaker: u.speaker, text: u.text))
                    await listener.note(speaker: u.speaker, text: u.text)
                case .ask(let a):
                    timeline.add(t: t, .manualAsk(intent: a.intent))
                    let intent = CoachIntent(rawValue: a.intent)
                    do {
                        let card = try await listener.manualCheck(intent: intent)
                        manualIDs.insert(card.id)
                    } catch {
                        timeline.add(t: t, .harnessNote("Manual ask FAILED with transport error: \(error)"))
                    }
                }
                itemIndex += 1
            }
            // One simulated cadence-loop tick per virtual second. The question
            // fast-path inside note() races a detached tick; the quiescence wait
            // below keeps the virtual clock still until any check completes.
            await listener.tick()
            while await listener.isCheckInFlight {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        await listener.endMeeting()
        healthTask.cancel()
        if let db {
            try? await db.close()
        }
        if let dbURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
            }
        }

        run.timeline = timeline.snapshot()
        aggregate(into: &run, manualIDs: manualIDs)
        run.verdicts = scenario.expect.map { evaluate($0, run: run) }
        return run
    }

    static func seedKnowledgeBase(
        docs: [BenchKbDoc], cache: KbCache, embedder: EmbeddingClient, config: EmbeddingConfig
    ) async throws -> Int {
        var total = 0
        for doc in docs {
            let sha = KbCache.sha256Hex(of: Data(doc.content.utf8))
            let outputs = MarkdownChunker.chunk(markdown: doc.content, sourceFile: doc.title)
            let pieces: [(text: String, breadcrumb: String)] =
                outputs.isEmpty
                ? [(text: doc.content, breadcrumb: doc.title)]
                : outputs.map { (text: $0.text, breadcrumb: $0.breadcrumb) }
            let vectors = try await embedder.embedForIndex(texts: pieces.map(\.text))
            for (piece, vector) in zip(pieces, vectors) {
                let chunk = KbChunk(
                    sourceFile: doc.title, breadcrumb: piece.breadcrumb, text: piece.text,
                    sourceSha256: sha, sourceKind: .playbook)
                try await cache.upsert(
                    chunk: chunk,
                    embedding: KbEmbedding(chunkId: chunk.id, vector: vector, configFingerprint: config.fingerprint),
                    config: config
                )
                total += 1
            }
        }
        return total
    }

    // MARK: Aggregation

    static func aggregate(into run: inout BenchScenarioRun, manualIDs: Set<UUID>) {
        var latencies: [Int] = []
        var sentChars = 0
        var replyChars = 0

        // Reconstruct checks: calls are single-flight, so a non-search call
        // followed by a search-round call is one check with the follow-up's
        // decision as the outcome.
        struct Call {
            let t: Int
            let latencyMs: Int
            let reply: String
            let directed: Bool
            let searchRound: Bool
            let failure: String?
        }
        var calls: [Call] = []
        for entry in run.timeline {
            switch entry.kind {
            case .modelCall(let ms, let sent, let reply, let directed, let searchRound, let failure):
                calls.append(
                    Call(t: entry.t, latencyMs: ms, reply: reply, directed: directed, searchRound: searchRound, failure: failure))
                latencies.append(ms)
                sentChars += sent
                replyChars += reply.count
            case .surfaced(let card):
                if manualIDs.contains(card.id) {
                    run.manualCards.append(card)
                } else {
                    run.autoCards.append(card)
                }
            case .withheld(_, let reason):
                switch reason {
                case .budgetExhausted: run.withheldBudget += 1
                case .tooSoon: run.withheldSpacing += 1
                case .duplicate: run.withheldDuplicate += 1
                case .unverifiableRecall: run.withheldRecall += 1
                }
            default:
                break
            }
        }
        run.modelCallCount = calls.count
        run.searchRounds = calls.filter(\.searchRound).count

        var index = 0
        while index < calls.count {
            let call = calls[index]
            index += 1
            guard !call.directed, !call.searchRound else { continue }
            var final = call
            var totalLatency = call.latencyMs
            if decisionIsSearch(reply: call.reply, failure: call.failure),
                index < calls.count, calls[index].searchRound
            {
                final = calls[index]
                totalLatency += calls[index].latencyMs
                index += 1
            }
            let outcome = describeDecision(reply: final.reply, failure: final.failure)
            let failed = final.failure != nil
            let decision = failed ? nil : CoachListener.parseDecision(final.reply)
            let spoke: Bool
            if case .card = decision { spoke = true } else { spoke = false }
            let unusable = !failed && decision == nil
            run.autoChecks.append(
                BenchCheckOutcome(
                    virtualT: call.t, latencyMs: totalLatency, finalDecision: outcome,
                    spoke: spoke, silent: !spoke && !unusable && !failed, unusable: unusable, failed: failed))
        }

        if !latencies.isEmpty {
            run.meanLatencyMs = latencies.reduce(0, +) / latencies.count
            run.maxLatencyMs = latencies.max() ?? 0
        }
        run.estTokens = (sentChars + replyChars) / 4
    }

    private static func decisionIsSearch(reply: String, failure: String?) -> Bool {
        guard failure == nil else { return false }
        if case .search = CoachListener.parseDecision(reply) { return true }
        return false
    }

    static func describeDecision(reply: String, failure: String?) -> String {
        if let failure {
            return "ERROR — \(String(failure.prefix(160)))"
        }
        switch CoachListener.parseDecision(reply) {
        case .silence:
            return "silence"
        case .card(let kind, let title, _, let grounding):
            let grounded = grounding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ", grounded"
            return "card[\(kind.rawValue)\(grounded)] \"\(title)\""
        case .search(let query):
            return "search(\"\(query)\")"
        case nil:
            return "UNUSABLE reply: \(String(reply.prefix(120)))"
        }
    }

    // MARK: Expectation evaluation

    static func normaliseForDuplicate(_ text: String) -> String {
        let lowered = text.lowercased()
        let filtered = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(filtered).split(separator: " ").joined(separator: " ")
    }

    static func containsAny(_ haystack: String, _ keywords: [String]) -> Bool {
        let lowered = haystack.lowercased()
        return keywords.contains { lowered.contains($0.lowercased()) }
    }

    static func evaluate(
        _ expectation: BenchExpectation, run: BenchScenarioRun
    ) -> (label: String, pass: Bool, detail: String) {
        let all = run.autoCards + run.manualCards
        switch expectation {
        case .silenceThroughout:
            let offenders = run.autoCards.map(\.title) + (run.withheldTotal > 0 ? ["(withheld cards)"] : [])
            let pass = run.autoCards.isEmpty && run.withheldTotal == 0
            return (
                expectation.label, pass,
                pass
                    ? "the coach stayed silent through every check"
                    : "the coach produced cards: \(offenders.joined(separator: "; "))"
            )
        case .cardCountMax(let max):
            let pass = run.autoCards.count <= max
            return (
                expectation.label, pass,
                "\(run.autoCards.count) automatic card(s) surfaced (limit \(max))"
            )
        case .answerContaining(let keywords):
            let match = all.first { containsAny($0.title + " " + $0.body, keywords) }
            return (
                expectation.label, match != nil,
                match.map { "matched card \"\($0.title)\": \(String($0.body.prefix(120)))" }
                    ?? "no surfaced card contained any of \(keywords)"
            )
        case .cardInLanguage(_, let keywords):
            let match = all.first { containsAny($0.body, keywords) }
            return (
                expectation.label, match != nil,
                match.map { "matched card \"\($0.title)\": \(String($0.body.prefix(120)))" }
                    ?? "no surfaced card body contained any of \(keywords)"
            )
        case .recallWithGrounding(let keywords):
            let match = all.first { $0.isGrounded && containsAny($0.title + " " + $0.body + " " + $0.grounding, keywords) }
            return (
                expectation.label, match != nil,
                match.map { "grounded card \"\($0.title)\" (grounding: \(String($0.grounding.prefix(100))))" }
                    ?? "no grounded card mentioned any of \(keywords)"
            )
        case .noDuplicateCards:
            var seenTitles: [String: String] = [:]
            var seenBodies: [String: String] = [:]
            for card in all {
                let title = normaliseForDuplicate(card.title)
                let body = normaliseForDuplicate(card.body)
                if !title.isEmpty, let first = seenTitles[title] {
                    return (expectation.label, false, "duplicate title \"\(card.title)\" (first shown as \"\(first)\")")
                }
                if !body.isEmpty, seenBodies[body] != nil {
                    return (expectation.label, false, "duplicate body on card \"\(card.title)\"")
                }
                seenTitles[title] = card.title
                seenBodies[body] = card.title
            }
            return (expectation.label, true, "\(all.count) card(s), all distinct")
        case .manualAlwaysAnswers:
            let asks = run.scenario.manualAsks?.count ?? 0
            let pass = run.manualCards.count == asks && asks > 0
                && run.manualCards.allSatisfy { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
            return (
                expectation.label, pass,
                "\(run.manualCards.count) manual card(s) for \(asks) ask(s)"
            )
        }
    }

    // MARK: Report

    static func formatT(_ t: Int) -> String {
        String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func buildReport(
        runs: [BenchScenarioRun], coachRoute: LLMRoute?, embedConfig: EmbeddingConfig, embeddingsOK: Bool
    ) -> String {
        var out: [String] = []
        out.append("# Coach bench report")
        out.append("")
        out.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append(
            "Coach route: \(coachRoute?.provider.rawValue ?? "?") · model `\(coachRoute?.model ?? "?")` · \(coachRoute?.baseURL?.absoluteString ?? "?")"
        )
        out.append(
            "Embedding route: \(embedConfig.model) via Ollama — \(embeddingsOK ? "available" : "UNREACHABLE (recall scenarios skipped; retrieval stubbed empty elsewhere)")"
        )
        out.append(
            "Listener config: cadence \(CoachConfig().effectiveCheckCadenceSeconds)s · budget \(CoachConfig().surfaceBudget) cards per \(CoachConfig().effectiveSurfaceWindowMinutes)-min window · spacing \(Int(CoachListener.minSecondsBetweenAutoCards))s · fast-path floor \(Int(CoachListener.minSecondsBetweenFastPathChecks))s"
        )
        out.append("")

        for run in runs {
            out.append("## \(run.scenario.name)")
            out.append("")
            out.append(run.scenario.description)
            out.append("")
            if let reason = run.skippedReason {
                out.append("**\(reason)**")
                out.append("")
                continue
            }
            out.append("### Timeline")
            out.append("")
            out.append("```")
            for entry in run.timeline {
                let t = formatT(entry.t)
                switch entry.kind {
                case .utterance(let speaker, let text):
                    out.append("[\(t)] \(speaker): \(text)")
                case .modelCall(let ms, let sent, let reply, let directed, let searchRound, let failure):
                    let tag = directed ? "MANUAL CHECK" : (searchRound ? "SEARCH ROUND" : "CHECK")
                    let decision = describeDecision(reply: reply, failure: failure)
                    out.append("[\(t)] \(tag) → \(decision)  (\(ms) ms, ~\(sent / 1000)k chars sent)")
                case .surfaced(let card):
                    let grounding = card.isGrounded ? "  [grounding: \(String(card.grounding.prefix(90)))]" : ""
                    out.append("[\(t)]   SURFACED [\(card.kind.rawValue)] \"\(card.title)\" — \(card.body)\(grounding)")
                case .withheld(let card, let reason):
                    out.append(
                        "[\(t)]   WITHHELD (\(reason.rawValue), \(reason.logDescription)) [\(card.kind.rawValue)] \"\(card.title)\" — \(card.body)")
                case .manualAsk(let intent):
                    out.append("[\(t)] MANUAL ASK (intent: \(intent))")
                case .health(let message):
                    out.append("[\(t)] HEALTH: \(message)")
                case .harnessNote(let note):
                    out.append("[\(t)] NOTE: \(note)")
                }
            }
            out.append("```")
            out.append("")
            out.append("### Expectations")
            out.append("")
            for verdict in run.verdicts {
                out.append("- \(verdict.pass ? "PASS" : "FAIL") `\(verdict.label)` — \(verdict.detail)")
            }
            out.append("")
            let spoke = run.autoChecks.filter(\.spoke).count
            let silent = run.autoChecks.filter(\.silent).count
            let unusable = run.autoChecks.filter(\.unusable).count
            let failed = run.autoChecks.filter(\.failed).count
            out.append(
                "Stats: \(run.autoChecks.count) automatic check(s) — spoke \(spoke), silent \(silent), unusable \(unusable), errors \(failed); "
                    + "cards surfaced \(run.autoCards.count) auto + \(run.manualCards.count) manual; "
                    + "withheld \(run.withheldBudget) (budget) / \(run.withheldSpacing) (spacing) / \(run.withheldDuplicate) (duplicate) / \(run.withheldRecall) (unverifiable recall); "
                    + "model calls \(run.modelCallCount) (incl. \(run.searchRounds) search round(s)); "
                    + "latency mean \(run.meanLatencyMs) ms, max \(run.maxLatencyMs) ms; ≈\(run.estTokens.formatted()) tokens."
            )
            out.append("")
        }

        // Summary table.
        out.append("## Summary")
        out.append("")
        out.append("| Scenario | Checks | Spoke | Silent | Cards (auto+manual) | Withheld | Expectations | Mean ms | Max ms | ≈Tokens |")
        out.append("|---|---|---|---|---|---|---|---|---|---|")
        var totalChecks = 0
        var totalSpoke = 0
        var totalSilent = 0
        var totalCards = 0
        var totalManual = 0
        var totalWithheld = 0
        var totalPass = 0
        var totalExpectations = 0
        var totalTokens = 0
        var allLatencyMax = 0
        var latencySum = 0
        var latencyCount = 0
        for run in runs {
            if run.skippedReason != nil {
                out.append("| \(run.scenario.name) | — | — | — | — | — | SKIPPED | — | — | — |")
                continue
            }
            let spoke = run.autoChecks.filter(\.spoke).count
            let silent = run.autoChecks.filter(\.silent).count
            let pass = run.verdicts.filter(\.pass).count
            out.append(
                "| \(run.scenario.name) | \(run.autoChecks.count) | \(spoke) | \(silent) | \(run.autoCards.count)+\(run.manualCards.count) | \(run.withheldTotal) | \(pass)/\(run.verdicts.count) | \(run.meanLatencyMs) | \(run.maxLatencyMs) | \(run.estTokens.formatted()) |"
            )
            totalChecks += run.autoChecks.count
            totalSpoke += spoke
            totalSilent += silent
            totalCards += run.autoCards.count
            totalManual += run.manualCards.count
            totalWithheld += run.withheldTotal
            totalPass += pass
            totalExpectations += run.verdicts.count
            totalTokens += run.estTokens
            allLatencyMax = max(allLatencyMax, run.maxLatencyMs)
            latencySum += run.meanLatencyMs * max(run.modelCallCount, 1)
            latencyCount += max(run.modelCallCount, 1)
        }
        let overallMean = latencyCount > 0 ? latencySum / latencyCount : 0
        out.append(
            "| **Total** | \(totalChecks) | \(totalSpoke) | \(totalSilent) | \(totalCards)+\(totalManual) | \(totalWithheld) | \(totalPass)/\(totalExpectations) | \(overallMean) | \(allLatencyMax) | \(totalTokens.formatted()) |"
        )
        out.append("")
        let skipped = runs.filter { $0.skippedReason != nil }
        if !skipped.isEmpty {
            out.append("**Skipped scenarios:** \(skipped.map(\.scenario.name).joined(separator: ", ")) — see the loud notes above.")
            out.append("")
        }
        if totalExpectations > 0 {
            let rate = Double(totalPass) / Double(totalExpectations) * 100
            out.append(String(format: "Expectation pass rate: %.0f%% (%d/%d).", rate, totalPass, totalExpectations))
        }
        return out.joined(separator: "\n")
    }
}
