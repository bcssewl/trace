import SharedCore
import XCTest

@testable import AppShell

@MainActor
final class MeetingLiveModelTests: XCTestCase {

    private func makeUtterance(
        t: Double,
        speaker: Utterance.Speaker,
        text: String,
        conf: Double = 0.9,
        cleaned: String? = nil
    ) -> Utterance {
        Utterance(t: t, speaker: speaker, text: text, conf: conf, asr: "parakeet", diar: nil, cleaned: cleaned)
    }

    func testBeginResetsState() {
        let model = MeetingLiveModel()
        model.appendCommitted(makeUtterance(t: 1, speaker: .you, text: "stale"))
        model.notes = "old notes"

        model.begin(sessionId: "session_x", title: "Sync")

        XCTAssertEqual(model.sessionId, "session_x")
        XCTAssertEqual(model.title, "Sync")
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertTrue(model.speakers.isEmpty)
        XCTAssertEqual(model.notes, "")
        XCTAssertEqual(model.health, .capturing)
    }

    func testAppendCommittedAddsTurnRegistersSpeakerAndClearsPartial() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.setPartial(speaker: "remote_1", text: "● speaking…")

        model.appendCommitted(makeUtterance(t: 2.3, speaker: .other(id: "remote_1"), text: "hello there"))

        XCTAssertEqual(model.turns.count, 1)
        let turn = try? XCTUnwrap(model.turns.first)
        XCTAssertEqual(turn?.speakerID, "remote_1")
        XCTAssertEqual(turn?.isYou, false)
        XCTAssertEqual(turn?.text, "hello there")
        XCTAssertNil(model.partials["remote_1"], "finalizing a turn clears that speaker's partial")
        XCTAssertEqual(model.speakers.count, 1)
        XCTAssertEqual(model.speakers.first?.turnCount, 1)
    }

    func testCleanedTextPreferredOverRaw() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.appendCommitted(makeUtterance(t: 0, speaker: .you, text: "raw", cleaned: "Cleaned."))
        XCTAssertEqual(model.turns.first?.text, "Cleaned.")
    }

    func testPartialSetAndClear() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")

        model.setPartial(speaker: "you", text: "● speaking…")
        XCTAssertEqual(model.partials["you"], "● speaking…")
        XCTAssertEqual(model.speakers.count, 1, "setting a partial registers the speaker")
        XCTAssertEqual(model.speakers.first?.turnCount, 0, "a partial is not a turn")

        model.clearPartial(speaker: "you")
        XCTAssertNil(model.partials["you"])
    }

    func testSpeakerDedupAndTurnCount() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.appendCommitted(makeUtterance(t: 0, speaker: .other(id: "remote_1"), text: "a"))
        model.appendCommitted(makeUtterance(t: 1, speaker: .other(id: "remote_1"), text: "b"))
        model.appendCommitted(makeUtterance(t: 2, speaker: .you, text: "c"))

        XCTAssertEqual(model.turns.count, 3)
        XCTAssertEqual(model.speakers.count, 2)
        let remote = model.speakers.first { $0.speakerID == "remote_1" }
        XCTAssertEqual(remote?.turnCount, 2)
    }

    func testDisplayNameDefaults() {
        let model = MeetingLiveModel()
        XCTAssertEqual(model.displayName(for: "you"), "You")
        XCTAssertEqual(model.displayName(for: "remote_1"), "Speaker 1")
        XCTAssertEqual(model.displayName(for: "system_audio"), "Others")
    }

    func testRenameSpeakerUpdatesDisplayName() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.appendCommitted(makeUtterance(t: 0, speaker: .other(id: "remote_1"), text: "hi"))

        model.renameSpeaker("remote_1", to: "Sarah Chen")

        XCTAssertEqual(model.displayName(for: "remote_1"), "Sarah Chen")
        XCTAssertEqual(model.speakers.first?.displayName, "Sarah Chen")

        model.renameSpeaker("remote_1", to: "   ")
        XCTAssertEqual(model.displayName(for: "remote_1"), "Speaker 1", "blank rename clears the override")
    }

    func testSummaryStreamingThenFinal() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.appendSummaryDelta("Decisions: ")
        model.appendSummaryDelta("ship it.")
        XCTAssertEqual(model.liveSummary, "Decisions: ship it.")
        XCTAssertEqual(model.summaryState, .streaming)

        model.setSummary("Final summary.", isFinal: true)
        XCTAssertEqual(model.summaryState, .final)
        XCTAssertEqual(model.liveSummary, "Final summary.")
    }

    // MARK: Offline diarization refinement

    func testApplyRefinedTurnsReplacesTurnsAndRebuildsSpeakers() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        // Live capture lumped the whole remote stream under system_audio.
        model.appendCommitted(makeUtterance(t: 0, speaker: .you, text: "hi"))
        model.appendCommitted(makeUtterance(t: 1, speaker: .other(id: "system_audio"), text: "a"))
        model.appendCommitted(makeUtterance(t: 2, speaker: .other(id: "system_audio"), text: "b"))
        XCTAssertEqual(model.speakers.count, 2)

        // The offline pass split the remote stream into two stable speakers.
        let refined = [
            makeUtterance(t: 0, speaker: .you, text: "hi"),
            makeUtterance(t: 1, speaker: .other(id: "remote_1"), text: "a"),
            makeUtterance(t: 2, speaker: .other(id: "remote_2"), text: "b"),
        ]
        model.applyRefinedTurns(refined)

        XCTAssertEqual(model.turns.map(\.speakerID), ["you", "remote_1", "remote_2"])
        XCTAssertEqual(Set(model.speakers.map(\.speakerID)), ["you", "remote_1", "remote_2"])
        XCTAssertEqual(model.displayName(for: "remote_2"), "Speaker 2")
        let remote1 = model.speakers.first { $0.speakerID == "remote_1" }
        XCTAssertEqual(remote1?.turnCount, 1)
    }

    func testApplyRefinedTurnsPreservesPerSessionRenames() {
        let model = MeetingLiveModel()
        model.begin(sessionId: "s", title: "t")
        model.appendCommitted(makeUtterance(t: 1, speaker: .other(id: "remote_1"), text: "a"))
        model.renameSpeaker("remote_1", to: "Alex")

        model.applyRefinedTurns([makeUtterance(t: 1, speaker: .other(id: "remote_1"), text: "a")])

        XCTAssertEqual(model.displayName(for: "remote_1"), "Alex", "renames survive a refinement swap")
        XCTAssertEqual(model.speakers.first?.displayName, "Alex")
    }
}
