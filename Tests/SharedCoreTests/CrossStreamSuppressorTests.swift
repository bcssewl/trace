import XCTest

@testable import SharedCore

final class CrossStreamSuppressorTests: XCTestCase {

    // MARK: - Echo detection within window

    func testIdenticalTextWithinWindowIsEcho() async {
        let suppressor = CrossStreamSuppressor(windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(text: "Let's move on to the next agenda item.", at: 10.0)

        let isEcho = await suppressor.isMicEcho(
            text: "Let's move on to the next agenda item.", at: 10.4)
        XCTAssertTrue(isEcho)
    }

    func testNearIdenticalTextWithinWindowIsEcho() async {
        let suppressor = CrossStreamSuppressor(jaccardThreshold: 0.78, windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(
            text: "I think we should ship the feature today.", at: 5.0)

        // One trailing word dropped — still well above the 0.78 Jaccard threshold.
        let isEcho = await suppressor.isMicEcho(
            text: "I think we should ship the feature", at: 5.5)
        XCTAssertTrue(isEcho)
    }

    // MARK: - Non-matches

    func testClearlyDifferentTextIsNotEcho() async {
        let suppressor = CrossStreamSuppressor()
        await suppressor.noteSystemUtterance(
            text: "The quarterly revenue numbers look strong.", at: 3.0)

        let isEcho = await suppressor.isMicEcho(
            text: "Can someone grab lunch for the team?", at: 3.2)
        XCTAssertFalse(isEcho)
    }

    func testIdenticalTextOutsideWindowIsNotEcho() async {
        let suppressor = CrossStreamSuppressor(windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(
            text: "Let's move on to the next agenda item.", at: 10.0)

        // 3s later — outside the 1.75s window.
        let isEcho = await suppressor.isMicEcho(
            text: "Let's move on to the next agenda item.", at: 13.0)
        XCTAssertFalse(isEcho)
    }

    func testEmptyAndVeryShortMicTextIsNotEcho() async {
        let suppressor = CrossStreamSuppressor()
        await suppressor.noteSystemUtterance(text: "yes absolutely", at: 1.0)

        let empty = await suppressor.isMicEcho(text: "", at: 1.1)
        XCTAssertFalse(empty)

        // Single word — below the 2-word minimum.
        let single = await suppressor.isMicEcho(text: "yes", at: 1.1)
        XCTAssertFalse(single)
    }

    // MARK: - Containment

    func testContainmentMicWordsSubsetOfLongerSystemUtteranceIsEcho() async {
        let suppressor = CrossStreamSuppressor(jaccardThreshold: 0.99, windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(
            text: "Could everyone please mute their microphones during the presentation today.",
            at: 20.0)

        // 4-word subset of the longer system utterance. Jaccard is far below
        // 0.99, so this can only pass via containment (smaller set >= 3 words).
        let isEcho = await suppressor.isMicEcho(
            text: "please mute their microphones", at: 20.3)
        XCTAssertTrue(isEcho)
    }

    func testContainmentBelowThreeWordsIsNotEcho() async {
        let suppressor = CrossStreamSuppressor(jaccardThreshold: 0.99, windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(
            text: "Could everyone please mute their microphones during the presentation today.",
            at: 20.0)

        // 2-word subset — containment requires >= 3 words, and Jaccard is tiny.
        let isEcho = await suppressor.isMicEcho(text: "please mute", at: 20.3)
        XCTAssertFalse(isEcho)
    }

    // MARK: - Eviction / window pruning

    func testEvictionOldEntriesDoNotMatch() async {
        let suppressor = CrossStreamSuppressor(windowSeconds: 1.75)
        await suppressor.noteSystemUtterance(
            text: "Old utterance that should be evicted soon.", at: 0.0)
        // A newer system utterance advances "newest" far past the window,
        // pruning the old one even before the mic query.
        await suppressor.noteSystemUtterance(
            text: "A completely fresh and different sentence here.", at: 100.0)

        let isEcho = await suppressor.isMicEcho(
            text: "Old utterance that should be evicted soon.", at: 0.5)
        XCTAssertFalse(isEcho)
    }

    func testMaxRetainedCapDropsOldest() async {
        // Cap of 2, but a window wide enough that none would be pruned by time.
        let suppressor = CrossStreamSuppressor(windowSeconds: 1000.0, maxRetained: 2)
        await suppressor.noteSystemUtterance(text: "first unique alpha bravo charlie", at: 0.0)
        await suppressor.noteSystemUtterance(text: "second unique delta echo foxtrot", at: 0.1)
        await suppressor.noteSystemUtterance(text: "third unique golf hotel india", at: 0.2)

        // The first (oldest) entry was dropped by the cap.
        let firstDropped = await suppressor.isMicEcho(
            text: "first unique alpha bravo charlie", at: 0.3)
        XCTAssertFalse(firstDropped)

        // The two most recent are still retained.
        let thirdKept = await suppressor.isMicEcho(
            text: "third unique golf hotel india", at: 0.3)
        XCTAssertTrue(thirdKept)
    }

    func testResetClearsRetainedUtterances() async {
        let suppressor = CrossStreamSuppressor()
        await suppressor.noteSystemUtterance(text: "this should be cleared by reset", at: 1.0)
        await suppressor.reset()

        let isEcho = await suppressor.isMicEcho(
            text: "this should be cleared by reset", at: 1.1)
        XCTAssertFalse(isEcho)
    }

    // MARK: - Pure helpers

    func testNormalizeStripsPunctuationLowercasesAndDedupes() {
        let words = CrossStreamSuppressor.normalize("Hello, HELLO!! world?  world.")
        XCTAssertEqual(words, ["hello", "world"])
    }

    func testNormalizeEmptyAndWhitespaceOnly() {
        XCTAssertTrue(CrossStreamSuppressor.normalize("").isEmpty)
        XCTAssertTrue(CrossStreamSuppressor.normalize("   \t\n  ").isEmpty)
        XCTAssertTrue(CrossStreamSuppressor.normalize("...,;:!?").isEmpty)
    }

    func testJaccardIdenticalAndDisjointAndEmpty() {
        let a: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(CrossStreamSuppressor.jaccard(a, a), 1.0, accuracy: 1e-9)
        XCTAssertEqual(CrossStreamSuppressor.jaccard(a, ["x", "y"]), 0.0, accuracy: 1e-9)
        XCTAssertEqual(CrossStreamSuppressor.jaccard([], []), 0.0, accuracy: 1e-9)
        // |∩| = 1 (a), |∪| = 4 (a,b,c,d) → 0.25
        XCTAssertEqual(
            CrossStreamSuppressor.jaccard(["a", "b", "c"], ["a", "d"]),
            0.25, accuracy: 1e-9)
    }

    // MARK: - AudioOutputRoute

    func testAudioOutputRouteCurrentDoesNotCrash() {
        // Environment-dependent CoreAudio call — assert only that it returns a
        // valid case without crashing.
        let route = AudioOutputRoute.current()
        switch route {
        case .headphones, .speakers, .unknown:
            XCTAssertTrue(true)
        }
    }

    func testRecommendsAECOnlyForSpeakers() {
        XCTAssertTrue(AudioOutputRoute.speakers.recommendsAEC)
        XCTAssertFalse(AudioOutputRoute.headphones.recommendsAEC)
        XCTAssertFalse(AudioOutputRoute.unknown.recommendsAEC)
    }
}
