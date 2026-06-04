import Foundation

/// Pure cross-meeting speaker-memory reconciliation (BAS-11, design §14.3).
///
/// Plain-language model: at the end of a meeting the offline diarizer gives us a
/// mean "voiceprint" for each remote speaker (`remote_1`, `remote_2`, …). We
/// compare each voiceprint against the project's saved address book of known
/// voices. A close-enough match (cosine ≥ threshold) means "we've heard this
/// person before" — so we auto-apply their saved name to the transcript. If the
/// user themselves named a speaker this meeting, that name is authoritative: we
/// save (or correct) that voiceprint under their name so the next meeting knows
/// it too. Speakers nobody named and we didn't recognise are left anonymous and
/// never written to the address book.
///
/// Everything here is deterministic and on-device — no I/O, no model calls — so
/// the persistence layer (``SpeakerMemoryStore``) just applies the decisions and
/// stamps `last_seen`.
public enum SpeakerMemoryReconciler {

    public struct Outcome: Sendable, Hashable {
        /// `remote_N` → name to auto-apply to the live transcript.
        ///
        /// Only contains
        /// matches the user did *not* already rename this session.
        public let nameAssignments: [String: String]
        /// Enrolled voiceprint records to persist: new enrollments from user
        /// renames, corrected records, and matched records re-asserted so the
        /// store can refresh their `last_seen`.
        ///
        /// Deduplicated by id.
        public let upserts: [EnrolledSpeaker]

        public init(nameAssignments: [String: String], upserts: [EnrolledSpeaker]) {
            self.nameAssignments = nameAssignments
            self.upserts = upserts
        }
    }

    /// Reconcile this meeting's voiceprints against the enrolled DB.
    ///
    /// - Parameters:
    ///   - speakerEmbeddings: mean voiceprint per `remote_N` (from the offline
    ///     refinement pass). Labels with no voiceprint can't be enrolled/matched.
    ///   - sessionNames: the user's in-session renames (`speakerID` → name).
    ///   - enrolled: the project's saved voiceprints.
    ///   - embeddingModel: identifier of the embedding model in use (stored so a
    ///     model change can be detected and stale-dimension records ignored).
    ///   - threshold: minimum cosine similarity to call it a match.
    ///   - makeID: id factory for new enrollments (injectable for deterministic tests).
    public static func reconcile(
        speakerEmbeddings: [String: [Float]],
        sessionNames: [String: String],
        enrolled: [EnrolledSpeaker],
        embeddingModel: String,
        threshold: Float = SpeakerEnrollment.defaultThreshold,
        makeID: () -> String = { UUID().uuidString }
    ) -> Outcome {
        var nameAssignments: [String: String] = [:]
        var upsertsByID: [String: EnrolledSpeaker] = [:]

        // Deterministic order so id minting / precedence is stable across runs.
        for label in speakerEmbeddings.keys.sorted() {
            guard let embedding = speakerEmbeddings[label], !embedding.isEmpty else { continue }
            let match = bestMatch(for: embedding, in: enrolled, threshold: threshold)
            let sessionName = sessionNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let sessionName, !sessionName.isEmpty {
                if let match, match.name.caseInsensitiveCompare(sessionName) == .orderedSame {
                    // The user confirmed the matched identity → refresh that
                    // record's voiceprint in place.
                    upsertsByID[match.id] = EnrolledSpeaker(
                        id: match.id, name: match.name, meanEmbedding: embedding, embeddingModel: embeddingModel
                    )
                } else {
                    // A different name → enroll a NEW voiceprint. Never reuse a
                    // matched record's id here: the match may be a false positive
                    // for a *different* person, and overwriting it would erase the
                    // person it actually belongs to. New identities only add.
                    let id = makeID()
                    upsertsByID[id] = EnrolledSpeaker(
                        id: id, name: sessionName, meanEmbedding: embedding, embeddingModel: embeddingModel
                    )
                }
                // No auto-assignment — the name is already in `speakerNames`.
            } else if let match {
                // Recognised a known voice: auto-apply the saved name and
                // re-assert the record (unchanged) so the store bumps last_seen.
                nameAssignments[label] = match.name
                if upsertsByID[match.id] == nil { upsertsByID[match.id] = match }
            }
            // else: nobody named it and we didn't recognise it → leave anonymous.
        }

        return Outcome(nameAssignments: nameAssignments, upserts: Array(upsertsByID.values))
    }

    /// Highest-cosine enrolled speaker at or above `threshold`, ignoring records
    /// whose embedding dimension differs (e.g. enrolled with a different model).
    private static func bestMatch(
        for embedding: [Float], in enrolled: [EnrolledSpeaker], threshold: Float
    ) -> EnrolledSpeaker? {
        var best: EnrolledSpeaker?
        var bestScore: Float = 0
        for candidate in enrolled where candidate.meanEmbedding.count == embedding.count {
            let score = CosineMath.cosineSimilarity(embedding, candidate.meanEmbedding)
            if score >= threshold, score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }
}
