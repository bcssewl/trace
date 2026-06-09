import Foundation
import SharedCore

public struct SmartRoutingInput: Sendable, Hashable {
    public let utterance: String
    public let utteranceClass: UtteranceClass
    public let regexHits: Set<RegexDetector.Marker>
    public let topRagHits: [VectorSearch.Hit]
    public let conversationState: String
    public let userRequested: Bool
    /// When set, a directed "Ask the coach" request that steers the prompt.
    public let intent: CoachIntent?

    public init(
        utterance: String, utteranceClass: UtteranceClass,
        regexHits: Set<RegexDetector.Marker>, topRagHits: [VectorSearch.Hit],
        conversationState: String, userRequested: Bool,
        intent: CoachIntent? = nil
    ) {
        self.utterance = utterance
        self.utteranceClass = utteranceClass
        self.regexHits = regexHits
        self.topRagHits = topRagHits
        self.conversationState = conversationState
        self.userRequested = userRequested
        self.intent = intent
    }
}

public struct SmartRoutingOutput: Sendable, Hashable {
    public let mode: CoachCardMode
    public let title: String
    /// One short "say this" line (≤ ~12 words).
    ///
    /// Prefer over `body`.
    public let lead: String
    /// ≤3 short supporting bullets (each ≤ ~8 words).
    public let points: [String]
    public let body: String
    public let attribution: String
    public let usedChunkIds: [String]

    public init(
        mode: CoachCardMode, title: String,
        lead: String = "", points: [String] = [],
        body: String = "",
        attribution: String, usedChunkIds: [String]
    ) {
        self.mode = mode
        self.title = title
        self.lead = lead
        self.points = points
        self.body = body
        self.attribution = attribution
        self.usedChunkIds = usedChunkIds
    }
}

public protocol SmartRouting: Sendable {
    func decide(_ input: SmartRoutingInput) async throws -> SmartRoutingOutput
}

public actor AppleFmSmartRouter: SmartRouting {
    // Raised from 0.7 (BAS-76 follow-up): only a STRONG match to a past meeting gets
    // surfaced verbatim, so a trivial coincidental match doesn't dump an old line.
    // Both forwarded to CoachThresholds — the single home for the pipeline's
    // tuning constants and their documented relationships.
    public static let strongGroundedCosine: Float = CoachThresholds.strongGroundedCosine
    public static let synthesizableMinCosine: Float = CoachThresholds.synthesizableMinCosine

    private let router: ModelRouter

    public init(router: ModelRouter) {
        self.router = router
    }

    public func decide(_ input: SmartRoutingInput) async throws -> SmartRoutingOutput {
        // Directed "Ask the coach" requests steer the prompt explicitly. Reframe and
        // Sound smart never want a verbatim grounded dump (they transform/elevate the
        // point), so they synthesize from any hits or fall back to general knowledge.
        // Answer and Fact check still prefer a strong verbatim playbook match.
        if let intent = input.intent {
            switch intent {
            case .reframe, .soundSmart:
                let hits = input.topRagHits.filter { $0.score >= Self.synthesizableMinCosine }
                if !hits.isEmpty {
                    return try await synthesizeFromHits(input: input, hits: Array(hits.prefix(4)))
                }
                return try await routeWithoutRag(input: input)
            case .answer, .factCheck:
                break  // fall through to the standard grounded-first routing below
            }
        }
        if let strong = input.topRagHits.first, strong.score > Self.strongGroundedCosine {
            let (lead, points) = Self.leadAndPoints(fromChunk: strong.chunk.text)
            return SmartRoutingOutput(
                mode: .grounded,
                title: strong.chunk.breadcrumb.isEmpty ? strong.chunk.sourceFile : strong.chunk.breadcrumb,
                lead: lead,
                points: points,
                body: strong.chunk.text,
                attribution: "playbook · \(strong.chunk.sourceFile)",
                usedChunkIds: [strong.chunk.id]
            )
        }
        let multiHits = input.topRagHits.filter { $0.score >= Self.synthesizableMinCosine }
        if multiHits.count >= 2 {
            return try await synthesizeFromHits(input: input, hits: Array(multiHits.prefix(4)))
        }
        return try await routeWithoutRag(input: input)
    }

    private func synthesizeFromHits(
        input: SmartRoutingInput, hits: [VectorSearch.Hit]
    ) async throws -> SmartRoutingOutput {
        var contextLines: [String] = []
        for (index, hit) in hits.enumerated() {
            contextLines.append(
                "[\(index + 1)] \(hit.chunk.breadcrumb.isEmpty ? hit.chunk.sourceFile : hit.chunk.breadcrumb)")
            contextLines.append(hit.chunk.text)
            contextLines.append("")
        }
        let wrapped = AntiInjectionGuard.wrap(contextLines.joined(separator: "\n"), source: .ragChunk)
        let userUtt = AntiInjectionGuard.wrap(input.utterance, source: .transcript)
        let directive = input.intent.map { "DIRECTED REQUEST: \(Self.intentDirective(for: $0))\n\n" } ?? ""
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: directive + """
                        You write one brief, glanceable coach card for the user during a live meeting, \
                        synthesized strictly from the provided playbook hits.
                        Rules:
                        - Ground every statement strictly in the hits below. Use ONLY what the hits say.
                        - Never fabricate facts, numbers, names, metrics, or features. If the hits do not \
                        cover something, leave it out — do not speculate or fill gaps from general knowledge.
                        - This is a peripheral card the user reads at a GLANCE while talking. Be terse.
                        - "title": 2–5 word context label (e.g. what they asked).
                        - "lead": ONE short say-this line, ≤ 12 words, plain language, no jargon.
                        - "points": up to 3 supporting facts from the hits, each ≤ 8 words.
                        - Do not include [N] markers in the user-facing text.

                        Respond ONLY with a single JSON object, no prose or code fences:
                        {"title":"...","lead":"...","points":["...","..."]}
                        """),
                LLMMessage(
                    role: .user,
                    content: """
                        Trigger utterance:
                        \(userUtt)

                        Playbook hits:
                        \(wrapped)
                        """),
            ],
            taskClass: .coachCardContent,
            temperature: 0.2,
            maxTokens: 220,
            responseFormat: .json
        )
        let response = try await router.generate(request)
        let json = Self.parseJsonObject(response.text)
        let title = (json?["title"] as? String) ?? "From your playbook"
        let lead = (json?["lead"] as? String) ?? ""
        let points = (json?["points"] as? [String]) ?? []
        // Fall back to the raw model text as body when JSON parsing fails, so a
        // non-conforming model still surfaces something usable.
        let body = lead.isEmpty ? response.text : ""
        return SmartRoutingOutput(
            mode: .synthesized,
            title: title,
            lead: lead,
            points: Array(points.prefix(3)),
            body: body,
            attribution: "playbook (\(hits.count) sources) · \(response.model)",
            usedChunkIds: hits.map(\.chunk.id)
        )
    }

    /// A directed-intent instruction prepended to the no-RAG system prompt when an
    /// "Ask the coach" button drove this request.
    ///
    /// Each forces a specific kind of
    /// card regardless of the priority-order routing the passive path uses. All fall
    /// back to general knowledge (no source line) when no playbook context applies.
    static func intentDirective(for intent: CoachIntent) -> String {
        switch intent {
        case .answer:
            return """
                The user pressed "Answer". Directly answer the question or point most \
                recently on the table, concisely, from general or industry knowledge. \
                Always use mode "general". If it is not phrased as a question, answer the \
                implied question the latest line raises.
                """
        case .reframe:
            return """
                The user pressed "Reframe". Treat the latest point as an objection or \
                pushback and give a persuasive reframe or objection-handling angle the \
                user can say back. Always use mode "reframe".
                """
        case .soundSmart:
            return """
                The user pressed "Sound smart". Give one crisp, credible talking point or \
                insight that elevates the current point and makes the user sound sharp. \
                Always use mode "general".
                """
        case .factCheck:
            return """
                The user pressed "Fact check". Identify the most recent specific claim in \
                the conversation and verify it from general knowledge: state plainly \
                whether it holds up and give the correction if it is off. Do NOT assert a \
                confident grounded verdict you cannot support, and never invent a source. \
                Always use mode "general".
                """
        }
    }

    private func routeWithoutRag(input: SmartRoutingInput) async throws -> SmartRoutingOutput {
        let userUtt = AntiInjectionGuard.wrap(input.utterance, source: .transcript)
        let directive = input.intent.map { "DIRECTED REQUEST: \(Self.intentDirective(for: $0))\n\n" } ?? ""
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: directive + """
                        You are a real-time meeting copilot for the user (the person wearing the app). You \
                        see the latest thing said in the conversation; no relevant playbook/private-doc \
                        match is available. Produce at most ONE short, glanceable card that helps the user \
                        respond right now.

                        Choose exactly one mode by following this PRIORITY ORDER and stop at the first that fits:

                        1. ANSWER THE QUESTION (mode "general"). If a question is being asked, answer it \
                        concisely from general or industry knowledge. Treat it as a question whenever you are \
                        ~50% or more confident one is being asked — tolerate transcription (ASR) errors and \
                        incomplete phrasing such as "what about…", "how did you…", and implied questions like \
                        "I'm curious about X" or "I wonder how X works". State the answer plainly; make clear \
                        it is general knowledge, not from the user's private documents.

                        2. DEFINE A TERM (mode "general"). If no explicit question, but a proper noun or \
                        technical term in the last ~10–15 words likely needs defining, give a one-line \
                        definition of that term.

                        3. ADVANCE THE CONVERSATION (mode "reframe"). If it is a description, story, or topic \
                        with no question, offer 1–3 short angles or follow-up questions the user could raise \
                        to move the conversation forward.

                        4. REFRAME (mode "reframe"). If answering well would require user-specific facts that \
                        are NOT available (not in the conversation and not in any provided context), do NOT \
                        invent them. Instead offer a framing or clarifying angle the user can take.

                        5. SILENT (mode "silent"). Only if nothing is genuinely useful, return mode "silent" \
                        with an empty body.

                        Hard rules:
                        - Never fabricate facts, numbers, names, metrics, or features. Use only what is in the \
                        conversation or provided context. If you don't know, say so plainly — do not speculate.
                        - This is a peripheral card the user reads at a GLANCE while talking. Be terse, plain \
                        language, NO jargon.
                        - "title": 2–4 word context label (e.g. what they asked).
                        - "lead": ONE short say-this line, ≤ 12 words. Empty for silent.
                        - "points": up to 3 supporting bullets, each ≤ 8 words. Empty array is fine.
                        - "attribution": names the basis briefly, e.g. "general knowledge" (empty for silent).

                        Respond ONLY with a single JSON object, no prose or code fences:
                        {"mode":"general|reframe|silent","title":"...","lead":"...","points":["..."],"attribution":"..."}
                        """),
                LLMMessage(
                    role: .user,
                    content: """
                        Utterance class: \(input.utteranceClass.rawValue)
                        Conversation state: \(input.conversationState)

                        Latest in conversation:
                        \(userUtt)
                        """),
            ],
            taskClass: .coachSmartRouting,
            temperature: 0.1,
            maxTokens: 200,
            responseFormat: .json
        )
        let response = try await router.generate(request)
        return decodeJsonResponse(text: response.text, fallbackModel: response.model)
    }

    private func decodeJsonResponse(text: String, fallbackModel: String) -> SmartRoutingOutput {
        guard let json = Self.parseJsonObject(text) else {
            return SmartRoutingOutput(mode: .silent, title: "", body: "", attribution: "", usedChunkIds: [])
        }
        let modeRaw = (json["mode"] as? String)?.lowercased() ?? "silent"
        let mode = CoachCardMode(rawValue: modeRaw) ?? .silent
        let title = (json["title"] as? String) ?? ""
        let lead = (json["lead"] as? String) ?? ""
        let points = (json["points"] as? [String]) ?? []
        // Tolerate older/non-conforming output that still emits a flat "body".
        let body = (json["body"] as? String) ?? ""
        let attribution = (json["attribution"] as? String) ?? "AI · \(fallbackModel)"
        return SmartRoutingOutput(
            mode: mode, title: title,
            lead: lead, points: Array(points.prefix(3)),
            body: body,
            attribution: attribution, usedChunkIds: []
        )
    }

    /// Derives a glanceable lead + up to 3 bullet points from a verbatim playbook
    /// chunk (the non-LLM grounded path).
    ///
    /// The first sentence becomes the say-this
    /// lead; subsequent sentences / list lines become key-fact bullets.
    static func leadAndPoints(fromChunk text: String) -> (lead: String, points: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }
        // Prefer explicit lines (bullet lists, paragraphs) when present.
        let lines =
            trimmed
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*›·")) }
            .filter { !$0.isEmpty }
        if lines.count > 1 {
            return (lines[0], Array(lines.dropFirst().prefix(3)))
        }
        // Single block: split into sentences.
        let sentences =
            trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = sentences.first else { return (trimmed, []) }
        return (first, Array(sentences.dropFirst().prefix(3)))
    }

    /// Parses a JSON object from model output, tolerating markdown code fences and
    /// leading/trailing prose by falling back to the outermost `{...}` span.
    private static func parseJsonObject(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return json
        }
        guard let open = text.firstIndex(of: "{"),
            let close = text.lastIndex(of: "}"),
            open < close
        else { return nil }
        let slice = text[open...close]
        guard let data = slice.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

public struct ScriptedSmartRouter: SmartRouting {
    public let outcome: SmartRoutingOutput
    public init(outcome: SmartRoutingOutput) { self.outcome = outcome }
    public func decide(_ input: SmartRoutingInput) async throws -> SmartRoutingOutput { outcome }
}
