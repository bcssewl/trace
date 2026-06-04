@preconcurrency import AVFoundation
import XCTest

@testable import SharedCore

final class SpeechBackendContractTests: XCTestCase {
    func testScriptedBackendConformsToContract() async throws {
        let backend = ScriptedTranscriptionBackend(text: "hello world")
        XCTAssertEqual(backend.displayName, "Scripted")
        let status = await backend.checkStatus()
        XCTAssertEqual(status, .ready)

        let text = try await backend.transcribe([0, 0, 0], locale: Locale(identifier: "en_US"), previousContext: nil)
        XCTAssertEqual(text, "hello world")
    }

    func testASRDeltaCarriesPartialAndFinalText() {
        XCTAssertEqual(ASRDelta.partial("hel").text, "hel")
        XCTAssertTrue(ASRDelta.final("hello").isFinal)
        XCTAssertEqual(ASRDelta.endpoint.text, "")
    }

    func testBackendStatusEquatableForReady() {
        XCTAssertEqual(BackendStatus.ready, BackendStatus.ready)
        XCTAssertNotEqual(BackendStatus.ready, BackendStatus.loaded)
    }
}

final class SpeechASRRouterTests: XCTestCase {
    func testDefaultRoutesCoverEveryTaskClass() async {
        let router = ASRRouter()
        for task in ASRTaskClass.allCases {
            let route = await router.route(for: task, projectID: nil)
            XCTAssertFalse(route.engineIdentifier.isEmpty)
        }
    }

    func testPerProjectOverrideWins() async {
        let project = UUID()
        let router = ASRRouter(overrides: [
            project: [
                .meetingCaptureLive: ASRRoute(
                    engineIdentifier: "appleSpeech", modelIdentifier: "en-US", allowsCloud: false)
            ]
        ])

        let route = await router.route(for: .meetingCaptureLive, projectID: project)
        XCTAssertEqual(route.engineIdentifier, "appleSpeech")
    }

    func testSensitiveLocalOnlyRefusesCloudOverride() async {
        let project = UUID()
        let router = ASRRouter(overrides: [
            project: [
                .sensitiveLocalOnly: ASRRoute(engineIdentifier: "groq", modelIdentifier: "whisper", allowsCloud: true)
            ]
        ])
        let route = await router.route(for: .sensitiveLocalOnly, projectID: project)
        XCTAssertFalse(route.allowsCloud)
        XCTAssertEqual(route.engineIdentifier, "parakeet")
    }
}

final class SpeechSpeakerEnrollmentTests: XCTestCase {
    func testMatchReturnsBestSpeakerAboveThreshold() async {
        let enrollment = SpeakerEnrollment(
            threshold: 0.6,
            speakers: [
                EnrolledSpeaker(id: "alice", name: "Alice", meanEmbedding: [1, 0, 0], embeddingModel: "wespeaker"),
                EnrolledSpeaker(id: "bob", name: "Bob", meanEmbedding: [0, 1, 0], embeddingModel: "wespeaker"),
            ]
        )
        let match = await enrollment.match(embedding: [0.95, 0.05, 0])
        XCTAssertEqual(match?.speaker.id, "alice")
    }

    func testMatchReturnsNilBelowThreshold() async {
        let enrollment = SpeakerEnrollment(
            threshold: 0.95,
            speakers: [
                EnrolledSpeaker(id: "alice", name: "Alice", meanEmbedding: [1, 0, 0], embeddingModel: "wespeaker")
            ]
        )
        let match = await enrollment.match(embedding: [0.6, 0.8, 0])
        XCTAssertNil(match)
    }
}
