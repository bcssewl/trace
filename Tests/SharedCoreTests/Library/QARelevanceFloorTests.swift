import XCTest

@testable import SharedCore

/// BAS-30: a cosine relevance floor on the dense arm of the hybrid Q&A pipeline so
/// genuinely-irrelevant chunks (`You: .`, `Yeah.`) aren't fed to the LLM.
///
/// The
/// lexical (FTS) arm is exempt — its hits matched query tokens by construction.
final class QARelevanceFloorTests: XCTestCase {

    private func hit(_ file: String, score: Float) -> VectorSearch.Hit {
        VectorSearch.Hit(
            chunk: KbChunk(sourceFile: file, breadcrumb: "", text: "t", sourceSha256: "s"),
            score: score
        )
    }

    func testFloorDropsWeakHits() {
        let kept = QASearchPipeline.aboveDenseFloor(
            [hit("a", score: 0.9), hit("b", score: 0.12)], floor: 0.3
        )
        XCTAssertEqual(kept.map(\.chunk.sourceFile), ["a"])
    }

    func testHitExactlyAtFloorIsKept() {
        let kept = QASearchPipeline.aboveDenseFloor([hit("a", score: 0.3)], floor: 0.3)
        XCTAssertEqual(kept.count, 1)
    }

    func testFloorZeroDisablesGate() {
        // A negative cosine survives when the gate is off (floor ≤ 0).
        let kept = QASearchPipeline.aboveDenseFloor([hit("a", score: -0.4)], floor: 0)
        XCTAssertEqual(kept.count, 1)
    }

    func testAllBelowFloorYieldsNothing() {
        let kept = QASearchPipeline.aboveDenseFloor(
            [hit("a", score: 0.1), hit("b", score: 0.05)], floor: 0.3
        )
        XCTAssertTrue(kept.isEmpty)
    }

    func testDefaultFloorIsInDesignedRange() {
        // The shipped default should sit in the ~0.25–0.35 band the design calls for.
        XCTAssertGreaterThanOrEqual(QASearchPipeline.defaultDenseFloor, 0.25)
        XCTAssertLessThanOrEqual(QASearchPipeline.defaultDenseFloor, 0.35)
    }
}
