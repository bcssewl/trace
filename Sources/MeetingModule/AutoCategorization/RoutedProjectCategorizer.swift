import Foundation
import SharedCore

/// Composes the deterministic ``ProjectCategorizer`` (name/attendee signals) with
/// the configurable LLM ``MeetingProjectClassifier`` (design §8.2, BAS-9).
///
/// The LLM
/// is the "final classifier": its confident pick boosts that project's score so a
/// meeting can auto-file even when the project name never appears verbatim in the
/// transcript. Manual overrides short-circuit (never re-categorized, §8.3).
public struct RoutedProjectCategorizer: Sendable {

    private let base: ProjectCategorizer
    private let classifier: MeetingProjectClassifier?

    public init(base: ProjectCategorizer, classifier: MeetingProjectClassifier?) {
        self.base = base
        self.classifier = classifier
    }

    public func categorize(
        _ input: MeetingCategorizationInput, projects: [ProjectCandidate], calendarTitle: String? = nil
    ) async throws -> CategorizationResult {
        let baseResult = try await base.categorize(input, projects: projects)
        guard baseResult.bucket != .manualOverride, let classifier else { return baseResult }
        let pick = await classifier.classify(
            transcriptPrefix: input.transcriptPrefix, calendarTitle: calendarTitle, projects: projects
        )
        return Self.merge(
            base: baseResult,
            pick: pick,
            autoAssignThreshold: ProjectCategorizer.autoAssignThreshold,
            askUserThreshold: ProjectCategorizer.askUserThreshold
        )
    }

    /// Fold an LLM pick into the deterministic scores: boost the picked project's
    /// confidence to `max(signalScore, llmConfidence)` (never downgrades a strong
    /// signal), re-sort, and re-derive the bucket.
    ///
    /// Pure. Manual overrides and a
    /// nil pick pass `base` through unchanged.
    public static func merge(
        base: CategorizationResult,
        pick: MeetingProjectClassifier.Pick?,
        autoAssignThreshold: Double,
        askUserThreshold: Double
    ) -> CategorizationResult {
        guard base.bucket != .manualOverride, let pick else { return base }
        var scores = base.scores
        if let index = scores.firstIndex(where: { $0.project.id == pick.projectID }) {
            let boosted = max(scores[index].confidence, pick.confidence)
            scores[index] = CategorizationScore(project: scores[index].project, confidence: boosted)
        }
        scores.sort { $0.confidence > $1.confidence }
        let top = scores.first?.confidence ?? 0
        let bucket: CategorizationBucket
        if top > autoAssignThreshold {
            bucket = .autoAssign
        } else if top >= askUserThreshold {
            bucket = .askUser
        } else {
            bucket = .inbox
        }
        return CategorizationResult(bucket: bucket, scores: scores)
    }
}
