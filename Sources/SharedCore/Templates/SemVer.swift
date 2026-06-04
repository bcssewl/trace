import Foundation

public struct SemVer: Sendable, Hashable, Comparable, LosslessStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ description: String) {
        let parts = description.split(separator: ".")
        guard parts.count == 3,
            let M = Int(parts[0]), let m = Int(parts[1]), let p = Int(parts[2]),
            M >= 0, m >= 0, p >= 0
        else { return nil }
        self.major = M
        self.minor = m
        self.patch = p
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let parsed = SemVer(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid SemVer: \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
