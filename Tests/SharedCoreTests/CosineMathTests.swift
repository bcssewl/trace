import XCTest

@testable import SharedCore

final class CosineMathTests: XCTestCase {
    func testL2NormZeroVector() {
        XCTAssertEqual(CosineMath.l2Norm([0, 0, 0]), 0)
    }

    func testL2NormUnitVector() {
        XCTAssertEqual(CosineMath.l2Norm([1, 0, 0]), 1, accuracy: 1e-6)
    }

    func testL2NormThreeFourFive() {
        XCTAssertEqual(CosineMath.l2Norm([3, 4]), 5, accuracy: 1e-6)
    }

    func testNormalizeProducesUnitNorm() {
        let v: [Float] = [3, 4]
        let n = CosineMath.normalize(v)
        XCTAssertEqual(CosineMath.l2Norm(n), 1, accuracy: 1e-6)
    }

    func testDotProductOrthogonalIsZero() {
        XCTAssertEqual(CosineMath.dotProduct([1, 0, 0], [0, 1, 0]), 0, accuracy: 1e-6)
    }

    func testDotProductParallel() {
        XCTAssertEqual(CosineMath.dotProduct([1, 2, 3], [1, 2, 3]), 14, accuracy: 1e-6)
    }

    func testCosineSimilarityIdentical() {
        XCTAssertEqual(CosineMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-6)
    }

    func testCosineSimilarityOrthogonal() {
        XCTAssertEqual(CosineMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-6)
    }

    func testCosineSimilarityOpposite() {
        XCTAssertEqual(CosineMath.cosineSimilarity([1, 1], [-1, -1]), -1, accuracy: 1e-6)
    }

    func testFloatArrayBlobRoundTrip() {
        let v: [Float] = [1.5, -2.25, 3.75, 0]
        let blob = v.toBlobData()
        XCTAssertEqual(blob.count, 16)
        let restored = [Float](blobData: blob)
        XCTAssertEqual(restored, v)
    }
}
