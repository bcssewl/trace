import Accelerate
import Foundation

public enum CosineMath {
    public static func l2Norm(_ vector: [Float]) -> Float {
        var result: Float = 0
        vDSP_svesq(vector, 1, &result, vDSP_Length(vector.count))
        return sqrt(result)
    }

    public static func normalize(_ vector: [Float]) -> [Float] {
        let norm = l2Norm(vector)
        guard norm > 0 else { return vector }
        var scale = 1.0 / norm
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &out, 1, vDSP_Length(vector.count))
        return out
    }

    public static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vector dimensions must match: \(a.count) vs \(b.count)")
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vector dimensions must match: \(a.count) vs \(b.count)")
        let dot = dotProduct(a, b)
        let normA = l2Norm(a)
        let normB = l2Norm(b)
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    public static func cosineSimilarityNormalized(_ a: [Float], _ b: [Float]) -> Float {
        dotProduct(a, b)
    }
}

extension Array where Element == Float {
    public func toBlobData() -> Data {
        withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    public init(blobData: Data) {
        let count = blobData.count / MemoryLayout<Float>.size
        self = blobData.withUnsafeBytes { raw -> [Float] in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }
}
