import XCTest

@testable import SharedCore

/// `SpeakerMemoryReconciler` is the pure heart of cross-meeting speaker memory
/// (BAS-11). Given this meeting's per-`remote_N` mean voiceprints, the user's
/// in-session renames, and the project's enrolled voiceprint DB, it decides:
///   - which auto-names to apply to the live transcript (DB matches the user
///     didn't already name), and
///   - which enrolled records to upsert (new enrollments from renames; matched
///     records to refresh).
/// On-device, deterministic, no I/O — so it's fully unit-testable with synthetic
/// embeddings.
final class SpeakerMemoryReconcilerTests: XCTestCase {

    private func speaker(_ id: String, _ name: String, _ emb: [Float]) -> EnrolledSpeaker {
        EnrolledSpeaker(id: id, name: name, meanEmbedding: emb, embeddingModel: "test-embed")
    }

    func testMatchedSpeakerWithNoRenameGetsAutoNameApplied() {
        let sarah = speaker("s1", "Sarah", [1, 0, 0])
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [1, 0, 0]],
            sessionNames: [:],
            enrolled: [sarah],
            embeddingModel: "test-embed"
        )
        XCTAssertEqual(outcome.nameAssignments, ["remote_1": "Sarah"])
        // The matched record is re-asserted so the store can bump last_seen.
        XCTAssertEqual(Set(outcome.upserts), [sarah])
    }

    func testCosineBelowThresholdDoesNotMatch() {
        let sarah = speaker("s1", "Sarah", [1, 0, 0])
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [0, 1, 0]],  // orthogonal → cos 0
            sessionNames: [:],
            enrolled: [sarah],
            embeddingModel: "test-embed"
        )
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        XCTAssertTrue(outcome.upserts.isEmpty)
    }

    func testSessionRenameOfUnknownSpeakerEnrollsNewVoiceprint() {
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [0, 2, 0]],
            sessionNames: ["remote_1": "Bob"],
            enrolled: [],
            embeddingModel: "test-embed",
            makeID: { "new-id" }
        )
        // User already set the name in-session, so no auto-assignment is emitted…
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        // …but the voiceprint is enrolled so future meetings recognise Bob.
        XCTAssertEqual(
            Set(outcome.upserts),
            [speaker("new-id", "Bob", [0, 2, 0])]
        )
    }

    func testRenamingAMatchedSpeakerToADifferentNameDoesNotClobberIt() {
        // The matcher thinks remote_1 is Sarah, but the user names them "Bob" — a
        // false-positive correction. We must NOT overwrite Sarah's record (that
        // would erase the real Sarah): Bob is enrolled as a brand-new voiceprint.
        let sarah = speaker("s1", "Sarah", [1, 0, 0])
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [1, 0, 0]],  // matches Sarah
            sessionNames: ["remote_1": "Bob"],  // but the user says it's Bob
            enrolled: [sarah],
            embeddingModel: "test-embed",
            makeID: { "bob-id" }
        )
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        XCTAssertEqual(Set(outcome.upserts), [speaker("bob-id", "Bob", [1, 0, 0])])
    }

    func testConfirmingAMatchedNameRefreshesTheSameRecordInPlace() {
        // The user types the same name the matcher proposed → a confirmation, so
        // we refresh that record's voiceprint in place (reuse the id).
        let sarah = speaker("s1", "Sarah", [1, 0, 0])
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [0.99, 0.01, 0]],  // matches Sarah
            sessionNames: ["remote_1": "sarah"],  // same name (any case)
            enrolled: [sarah],
            embeddingModel: "test-embed"
        )
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        XCTAssertEqual(outcome.upserts, [speaker("s1", "Sarah", [0.99, 0.01, 0])])
    }

    func testUnnamedUnmatchedSpeakerIsNotPersisted() {
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [1, 1, 1]],
            sessionNames: [:],
            enrolled: [],
            embeddingModel: "test-embed"
        )
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        XCTAssertTrue(outcome.upserts.isEmpty)
    }

    func testLabelWithoutEmbeddingIsIgnoredEvenWhenRenamed() {
        // The diarizer produced no voiceprint for remote_1 (not in the map), so we
        // can't enroll it — a rename can't persist a voiceprint that doesn't exist.
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: [:],
            sessionNames: ["remote_1": "Bob"],
            enrolled: [],
            embeddingModel: "test-embed"
        )
        XCTAssertTrue(outcome.nameAssignments.isEmpty)
        XCTAssertTrue(outcome.upserts.isEmpty)
    }

    func testBestMatchWinsAmongSeveralAboveThreshold() {
        let close = speaker("s1", "Close", [0.98, 0.2, 0])
        let exact = speaker("s2", "Exact", [1, 0, 0])
        let outcome = SpeakerMemoryReconciler.reconcile(
            speakerEmbeddings: ["remote_1": [1, 0, 0]],
            sessionNames: [:],
            enrolled: [close, exact],
            embeddingModel: "test-embed"
        )
        XCTAssertEqual(outcome.nameAssignments, ["remote_1": "Exact"])
        XCTAssertEqual(Set(outcome.upserts), [exact])
    }
}
