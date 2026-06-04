import Foundation
import SharedCore

public protocol TemplateMerging: Sendable {
    func merge(renderedContext: String, taskClass: String) async throws
}

public actor MergerOrchestrator: MeetingMerging {
    public static let smartCapThreshold = 60_000

    private let merge: any TemplateMerging

    public init(merge: any TemplateMerging) {
        self.merge = merge
    }

    public func merge(_ context: FinalizedMeetingContext) async throws {
        let rendered = Self.composeRenderedContext(context: context)
        try await merge.merge(renderedContext: rendered, taskClass: "meetingAugmentedMerge")
    }

    public static func composeRenderedContext(context: FinalizedMeetingContext) -> String {
        let pieces: [String] = [
            wrap(source: .transcript, text: smartCap(context.transcriptJSONL)),
            wrap(source: .scratchpad, text: context.scratchpadMarkdown),
            wrap(source: .calendar, text: context.calendarText),
            wrap(source: .priorNotes, text: context.priorNotesMarkdown),
        ]
        return pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func wrap(source: UntrustedSource, text: String) -> String {
        AntiInjectionGuard.wrap(text, source: source)
    }

    public static func smartCap(_ text: String, threshold: Int = smartCapThreshold) -> String {
        guard text.count > threshold else { return text }
        let third = threshold / 3
        let first = text.prefix(third)
        let last = text.suffix(third)
        return "\(first)\n[... \(text.count - 2 * third) middle utterances omitted ...]\n\(last)"
    }
}
