import Foundation
import SharedCore

/// Real, deterministic implementation of ``CategorizationSignalProviding``.
///
/// Computes the five weighted signals used by ``ProjectCategorizer`` purely from
/// the fields that actually exist on ``MeetingCategorizationInput`` and
/// ``ProjectCandidate`` today. It performs no LLM calls, no I/O, and no system
/// access, so it is safe to call from any actor context.
///
/// Field coverage (see ``ProjectCategorizer.swift`` for the type definitions):
/// - `regex`  — derived from `project.name` matched against
///   `meeting.transcriptPrefix` (case-insensitive, token-aware).
/// - `attendee` — derived from the attendee email local-parts/domains in
///   `meeting.attendeeEmails` overlapped (Jaccard) with the tokens of
///   `project.name`. `ProjectCandidate` exposes no explicit attendee roster, so
///   the project name is the only matchable surface; absent any tokens the
///   signal is `0`.
/// - `content` — `0`. Neither type carries an embedding/centroid field, so there
///   is nothing to compare; we deliberately do not invent an embedding pipeline.
/// - `recurring` — `0`. Neither type carries a recurring/series field.
/// - `manualHistory` — `0`. Neither type carries a manual-history field.
public struct MeetingCategorizationSignalProvider: CategorizationSignalProviding {
    public init() {}

    public func signals(
        for meeting: MeetingCategorizationInput, project: ProjectCandidate
    ) async throws -> CategorizationSignals {
        let regex = Self.regexSignal(project: project, transcriptPrefix: meeting.transcriptPrefix)
        let attendee = Self.attendeeSignal(project: project, attendeeEmails: meeting.attendeeEmails)

        Loggers.meeting.debug(
            "categorization signals project=\(project.name, privacy: .public) regex=\(regex, privacy: .public) attendee=\(attendee, privacy: .public)"
        )

        return CategorizationSignals(
            regex: regex,
            attendee: attendee,
            content: 0,
            recurring: 0,
            manualHistory: 0
        )
    }

    // MARK: - Pure helpers

    /// Case-insensitive title/regex match of a project name against the meeting
    /// transcript prefix.
    ///
    /// - Returns `1.0` when the full normalized project name appears as a
    ///   substring of the transcript prefix.
    /// - Returns a scaled value in `(0, 1)` equal to the fraction of the
    ///   project's name tokens that appear as whole-word matches in the prefix,
    ///   when the full name does not match but some tokens do.
    /// - Returns `0` otherwise, or when the project name has no usable tokens.
    static func regexSignal(project: ProjectCandidate, transcriptPrefix: String) -> Double {
        let haystack = normalize(transcriptPrefix)
        let needle = normalize(project.name)
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }

        // Whole-name substring match wins outright.
        if haystack.contains(needle) {
            return 1.0
        }

        let nameTokens = tokens(from: project.name)
        guard !nameTokens.isEmpty else { return 0 }

        let haystackTokens = Set(tokens(from: transcriptPrefix))
        guard !haystackTokens.isEmpty else { return 0 }

        let matched = nameTokens.filter { haystackTokens.contains($0) }.count
        guard matched > 0 else { return 0 }

        return clamp(Double(matched) / Double(nameTokens.count))
    }

    /// Jaccard overlap between attendee-derived tokens (email local-parts and
    /// domain labels) and the project-name tokens.
    ///
    /// `ProjectCandidate` carries no attendee roster, so the project name is the
    /// only matchable surface. When either side has no tokens the signal is `0`.
    static func attendeeSignal(project: ProjectCandidate, attendeeEmails: [String]) -> Double {
        let projectTokens = Set(tokens(from: project.name))
        guard !projectTokens.isEmpty else { return 0 }

        var attendeeTokens: Set<String> = []
        for email in attendeeEmails {
            attendeeTokens.formUnion(emailTokens(from: email))
        }
        guard !attendeeTokens.isEmpty else { return 0 }

        return jaccard(projectTokens, attendeeTokens)
    }

    /// Jaccard index of two token sets: `|A ∩ B| / |A ∪ B|`.
    ///
    /// Returns `0` when
    /// the union is empty.
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return clamp(Double(intersection) / Double(union))
    }

    // MARK: - Tokenization

    /// Lowercases and trims a string for substring comparison.
    static func normalize(_ string: String) -> String {
        string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a free-text string into lowercased alphanumeric word tokens,
    /// dropping single-character noise tokens.
    static func tokens(from string: String) -> [String] {
        string
            .lowercased()
            .components(separatedBy: tokenSeparators)
            .filter { $0.count > 1 }
    }

    /// Tokens derived from an email address: the local-part words plus the
    /// domain labels (excluding the trailing public-suffix-style short label).
    static func emailTokens(from email: String) -> [String] {
        let trimmed = normalize(email)
        guard !trimmed.isEmpty else { return [] }

        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        var result: [String] = []

        // Local-part tokens (e.g. "jane.doe" -> ["jane", "doe"]).
        if let local = parts.first {
            result.append(contentsOf: tokens(from: String(local)))
        }

        // Domain labels (e.g. "acme-corp.com" -> ["acme", "corp"]); drop the
        // final label which is almost always a TLD ("com", "io", ...).
        if parts.count > 1 {
            let domain = String(parts[1])
            var labels = domain.split(separator: ".").map(String.init)
            if labels.count > 1 {
                labels.removeLast()
            }
            for label in labels {
                result.append(contentsOf: tokens(from: label))
            }
        }

        return result
    }

    /// Everything that is not an alphanumeric is treated as a token boundary.
    private static let tokenSeparators = CharacterSet.alphanumerics.inverted

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
