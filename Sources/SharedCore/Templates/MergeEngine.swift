import Foundation

public protocol ModelRoutingFacade: Sendable {
    func stream(_ request: LLMRequest, routeOverride: LLMRoute?) -> AsyncThrowingStream<LLMDelta, Error>
    /// The per-project LLM route override for a task, or nil to use the global
    /// preset (BAS-23). Defaulted to nil so non-project-aware routers / test
    /// fakes need not implement it.
    func projectRoute(forLLM task: LLMTaskClass, projectID: UUID?) async -> LLMRoute?
}

extension ModelRoutingFacade {
    public func projectRoute(forLLM task: LLMTaskClass, projectID: UUID?) async -> LLMRoute? { nil }
}

extension ModelRouter: ModelRoutingFacade {
    public nonisolated func stream(
        _ request: LLMRequest,
        routeOverride: LLMRoute?
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let resolvedRoute: LLMRoute
                    if let routeOverride {
                        resolvedRoute = routeOverride
                    } else {
                        resolvedRoute = try await self.route(forLLM: request.taskClass)
                    }
                    guard let provider = await self.llmProvider(for: resolvedRoute.provider) else {
                        throw TraceError.modelProviderFailed(
                            provider: resolvedRoute.provider.rawValue,
                            underlying: TraceError.configInvalid(field: "provider", reason: "not registered")
                        )
                    }
                    for try await delta in provider.stream(request, route: resolvedRoute) {
                        continuation.yield(delta)
                        if delta.isFinal { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public actor MergeEngine {
    public static let localOnlyOverride = LLMRoute(provider: .appleFM, model: "apple-fm-default")

    private let router: any ModelRoutingFacade

    public init(router: any ModelRoutingFacade) {
        self.router = router
    }

    public nonisolated func stream(
        template: Template,
        context: RenderContext,
        projectId: UUID?,
        steer: String = ""
    ) -> AsyncThrowingStream<MergeDelta, Error> {
        AsyncThrowingStream { continuation in
            Task { [router] in
                do {
                    let cappedTranscript = SmartCap.trim(transcript: context.transcript)
                    let cappedContext = RenderContext(
                        transcript: cappedTranscript,
                        scratchpad: context.scratchpad,
                        calendarUntrusted: context.calendarUntrusted,
                        priorNotesUntrusted: context.priorNotesUntrusted,
                        projectVocab: context.projectVocab,
                        conversationState: context.conversationState
                    )
                    // A global grounding rule prepended to every template's system
                    // prompt. Without it, weaker/local models pad empty sections
                    // into invented "we discussed…" narratives on thin transcripts.
                    let groundingRule =
                        template.dynamicSections
                        ? """
                        You write meeting notes. Use ONLY the transcript and user notes in the user message as facts. \
                        Never invent, assume, infer, or embellish anything not explicitly present — no fabricated \
                        decisions, names, numbers, or action items. Group the notes under headings that fit what was \
                        actually discussed, and omit any topic with no supporting content rather than writing a \
                        placeholder. If the transcript is empty, very short, or has too little to summarize, say that \
                        plainly in one short line instead of inventing structure. Do not pad.
                        """
                        : """
                        You write meeting notes. Use ONLY the transcript and user notes in the user message as facts. \
                        Never invent, assume, infer, or embellish anything not explicitly present — no fabricated \
                        decisions, names, numbers, or action items. If a section has no supporting content, write "None". \
                        If the transcript is empty, very short, or has too little to summarize, say that plainly in the \
                        Summary and put "None" in the other sections. Do not pad.
                        """
                    let resolvedSystem =
                        groundingRule + "\n\n"
                        + MustacheResolver.resolve(
                            template: template.systemPrompt, context: cappedContext
                        )
                    let userContent = Self.buildUserContent(template: template, context: cappedContext, steer: steer)
                    let request = LLMRequest(
                        messages: [
                            LLMMessage(role: .system, content: resolvedSystem),
                            LLMMessage(role: .user, content: userContent),
                        ],
                        taskClass: .meetingAugmentedMerge
                    )
                    var routeOverride: LLMRoute? =
                        (template.knobs.cloudRouting == .forceLocalOnly)
                        ? MergeEngine.localOnlyOverride
                        : template.modelRouteOverride
                    // Per-project override (BAS-23): when the template doesn't
                    // force a route, a project's `.meetingAugmentedMerge` route
                    // wins over the global preset. Applies to both meeting notes
                    // and file summaries (both flow through this engine).
                    if routeOverride == nil, let projectId {
                        routeOverride = await router.projectRoute(
                            forLLM: .meetingAugmentedMerge, projectID: projectId
                        )
                    }
                    let routeDescription = Self.describeRoute(
                        override: routeOverride, templateForce: template.knobs.cloudRouting
                    )
                    continuation.yield(
                        .began(
                            templateId: template.id,
                            templateName: template.name,
                            routeDescription: routeDescription
                        ))

                    var assembled = ""
                    var emittedSections: Set<String> = []
                    for try await delta in router.stream(request, routeOverride: routeOverride) {
                        if !delta.textIncrement.isEmpty {
                            assembled += delta.textIncrement
                            continuation.yield(.token(delta.textIncrement))
                            Self.detectSectionBoundaries(
                                assembled: assembled,
                                sections: template.outputSections,
                                emitted: &emittedSections,
                                continuation: continuation
                            )
                        }
                        if delta.isFinal { break }
                    }
                    continuation.yield(.completed(finalText: assembled))
                    continuation.finish()
                } catch let err as TraceError {
                    continuation.yield(.failed(err))
                    continuation.finish()
                } catch {
                    let wrapped = TraceError.modelProviderFailed(provider: "merge", underlying: error)
                    continuation.yield(.failed(wrapped))
                    continuation.finish()
                }
            }
        }
    }

    private static func buildUserContent(template: Template, context: RenderContext, steer: String) -> String {
        var lines: [String] = []
        if template.dynamicSections {
            lines.append(
                "Produce notes whose section headings fit THIS meeting — choose them yourself from the topics actually discussed; do not use a fixed set of sections."
            )
            lines.append("- Use a Markdown H3 (\"### \") heading for each topic, named for what was discussed.")
            lines.append("- Under each heading use bullet points; nest one level of sub-bullets for supporting detail.")
            lines.append("- Order sections to follow the meeting's importance and flow.")
            lines.append(
                "- Omit any topic with no supporting content — never emit an empty heading or a \"None\" placeholder.")
            lines.append("- Capture concrete specifics that were actually said (names, numbers, decisions, dates).")
        } else {
            lines.append("Produce notes under exactly these section headings, as Markdown H4:")
            for section in template.outputSections {
                lines.append("- #### \(section)")
            }
        }
        lines.append("")
        lines.append("Apply these output constraints:")
        lines.append("- Tone: \(template.knobs.tone.rawValue)")
        lines.append("- Audience: \(template.knobs.audience.rawValue)")
        lines.append("- Quote handling: \(template.knobs.quoteHandling.rawValue)")
        lines.append("- Action items: \(template.knobs.actionItemFormat.rawValue)")
        lines.append("- Length: \(template.knobs.length.rawValue)")
        let trimmedSteer = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSteer.isEmpty {
            lines.append("")
            lines.append("EMPHASIS FOR THIS VERSION (prioritize this, but stay grounded in the transcript):")
            lines.append(trimmedSteer)
        }
        // The actual content to summarize. The template's system prompt may not
        // carry a {{transcript}} placeholder, so the sources MUST be included
        // here or the model is told to summarize a transcript it can't see.
        lines.append("")
        lines.append("=== MEETING TRANSCRIPT ===")
        lines.append(context.transcript.isEmpty ? "(no transcript was captured)" : context.transcript)
        if !context.scratchpad.isEmpty {
            lines.append("")
            lines.append("=== USER NOTES (scratchpad) ===")
            lines.append(context.scratchpad)
        }
        if !context.calendarUntrusted.isEmpty {
            lines.append("")
            lines.append("=== CALENDAR ===")
            lines.append(context.calendarUntrusted)
        }
        if !context.priorNotesUntrusted.isEmpty {
            lines.append("")
            lines.append("=== PRIOR MEETING NOTES ===")
            lines.append(context.priorNotesUntrusted)
        }
        return lines.joined(separator: "\n")
    }

    private static func describeRoute(
        override: LLMRoute?, templateForce: TemplateKnobs.CloudRoutingPolicy
    ) -> String {
        if templateForce == .forceLocalOnly {
            return "appleFM (template HIPAA force)"
        }
        if let override {
            return "\(override.provider.rawValue):\(override.model) (override)"
        }
        return "default route for meetingAugmentedMerge"
    }

    private static func detectSectionBoundaries(
        assembled: String,
        sections: [String],
        emitted: inout Set<String>,
        continuation: AsyncThrowingStream<MergeDelta, Error>.Continuation
    ) {
        for section in sections where !emitted.contains(section) {
            let needle = "#### \(section)"
            if assembled.contains(needle) {
                emitted.insert(section)
                continuation.yield(.sectionStarted(section))
            }
        }
    }
}
