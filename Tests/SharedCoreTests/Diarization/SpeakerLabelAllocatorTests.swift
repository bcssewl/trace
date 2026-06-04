import XCTest

@testable import SharedCore

/// `SpeakerLabelAllocator` turns whatever opaque cluster ids a diarization engine
/// emits (FluidAudio's "1"/"2", Pyannote's "0"/"1", …) into the stable
/// `remote_1 / remote_2 / …` labels the rest of the app understands, numbering by
/// first appearance.
///
/// It is the shared half of both the live and offline passes.
final class SpeakerLabelAllocatorTests: XCTestCase {

    func testFirstClusterBecomesRemote1AndIsStable() {
        var allocator = SpeakerLabelAllocator()
        XCTAssertEqual(allocator.label(forEngineCluster: "7"), "remote_1")
        // Same engine cluster always resolves to the same remote label.
        XCTAssertEqual(allocator.label(forEngineCluster: "7"), "remote_1")
    }

    func testDistinctClustersGetIncreasingLabelsByFirstAppearance() {
        var allocator = SpeakerLabelAllocator()
        XCTAssertEqual(allocator.label(forEngineCluster: "0"), "remote_1")
        XCTAssertEqual(allocator.label(forEngineCluster: "1"), "remote_2")
        XCTAssertEqual(allocator.label(forEngineCluster: "2"), "remote_3")
        // Re-querying earlier clusters keeps their original assignment.
        XCTAssertEqual(allocator.label(forEngineCluster: "1"), "remote_2")
        XCTAssertEqual(allocator.label(forEngineCluster: "0"), "remote_1")
    }

    func testNumberingFollowsAppearanceOrderNotEngineId() {
        var allocator = SpeakerLabelAllocator()
        // A high engine id seen first still becomes remote_1.
        XCTAssertEqual(allocator.label(forEngineCluster: "42"), "remote_1")
        XCTAssertEqual(allocator.label(forEngineCluster: "5"), "remote_2")
    }

    func testHandlesArbitraryStringClusterIds() {
        var allocator = SpeakerLabelAllocator()
        XCTAssertEqual(allocator.label(forEngineCluster: "speaker_a"), "remote_1")
        XCTAssertEqual(allocator.label(forEngineCluster: "speaker_b"), "remote_2")
        XCTAssertEqual(allocator.label(forEngineCluster: "speaker_a"), "remote_1")
    }

    func testKnownLabelLookupDoesNotAllocate() {
        var allocator = SpeakerLabelAllocator()
        XCTAssertNil(allocator.existingLabel(forEngineCluster: "9"))
        _ = allocator.label(forEngineCluster: "9")
        XCTAssertEqual(allocator.existingLabel(forEngineCluster: "9"), "remote_1")
        // A peek at an unknown cluster must not consume a number.
        XCTAssertNil(allocator.existingLabel(forEngineCluster: "unseen"))
        XCTAssertEqual(allocator.label(forEngineCluster: "10"), "remote_2")
    }
}
