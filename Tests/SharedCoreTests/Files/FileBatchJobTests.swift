import XCTest

@testable import SharedCore

final class FileBatchJobTests: XCTestCase {

    func testAudioExtensionsAreDetected() {
        let cases: [(String, FileBatchJob.Kind)] = [
            ("clip.m4a", .audio),
            ("clip.MP3", .audio),
            ("clip.wav", .audio),
            ("clip.flac", .audio),
            ("clip.aiff", .audio),
        ]
        for (name, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            let job = FileBatchJob.makeIfSupported(url: url, origin: .dragDrop)
            XCTAssertEqual(job?.kind, expected, "extension \(name) should map to \(expected)")
        }
    }

    func testVideoExtensionsAreDetected() {
        for ext in FileBatchJob.videoExtensions {
            let url = URL(fileURLWithPath: "/tmp/clip.\(ext)")
            let job = FileBatchJob.makeIfSupported(url: url, origin: .dragDrop)
            XCTAssertEqual(job?.kind, .video, "extension \(ext) should be video")
        }
    }

    func testUnsupportedExtensionsRejected() {
        for ext in ["txt", "md", "pdf", "doc", "zip", "tar"] {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertNil(FileBatchJob.makeIfSupported(url: url, origin: .dragDrop), "\(ext) must be rejected")
        }
    }

    func testResolvedASRTaskRoutesByLocale() {
        let audioURL = URL(fileURLWithPath: "/tmp/clip.m4a")
        let job = FileBatchJob.makeIfSupported(url: audioURL, origin: .dragDrop)!

        let en = job.resolvedASRTask(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(en, .fileBatchEnglish)

        let zh = job.resolvedASRTask(locale: Locale(identifier: "zh_CN"))
        XCTAssertEqual(zh, .fileBatchCJK)

        let ja = job.resolvedASRTask(locale: Locale(identifier: "ja_JP"))
        XCTAssertEqual(ja, .fileBatchCJK)

        let fr = job.resolvedASRTask(locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(fr, .fileBatchMulti)
    }

    func testVoiceMemoJobAlwaysRoutesToVoiceMemoTask() {
        let url = URL(fileURLWithPath: "/tmp/memo.caf")
        let job = FileBatchJob(
            sourceURL: url, kind: .voiceMemo, origin: .voiceMemoCapture
        )
        XCTAssertEqual(job.resolvedASRTask(locale: Locale(identifier: "en_US")), .voiceMemo)
        XCTAssertEqual(job.resolvedASRTask(locale: Locale(identifier: "zh_CN")), .voiceMemo)
    }

    func testExplicitOverrideWinsAgainstHeuristics() {
        let url = URL(fileURLWithPath: "/tmp/clip.m4a")
        let job = FileBatchJob.makeIfSupported(
            url: url, origin: .dragDrop, asrTaskOverride: .qualityBatch
        )!
        XCTAssertEqual(job.resolvedASRTask(locale: Locale(identifier: "en_US")), .qualityBatch)
    }

    func testJobsAreSendableCodableValueTypes() throws {
        let url = URL(fileURLWithPath: "/tmp/clip.m4a")
        let job = FileBatchJob.makeIfSupported(
            url: url, origin: .dragDrop, projectID: "proj-1"
        )!
        let data = try JSONEncoder().encode(job)
        let roundTrip = try JSONDecoder().decode(FileBatchJob.self, from: data)
        XCTAssertEqual(roundTrip, job)
    }
}
