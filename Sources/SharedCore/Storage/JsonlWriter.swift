import Foundation

public actor JsonlWriter {
    private let url: URL
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder

    public init(url: URL) {
        self.url = url
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc
    }

    private func openIfNeeded() throws -> FileHandle {
        if let handle = fileHandle {
            return handle
        }
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        fileHandle = handle
        return handle
    }

    public func append<T: Encodable>(_ value: T) throws {
        let handle = try openIfNeeded()
        let jsonData = try encoder.encode(value)
        try handle.write(contentsOf: jsonData)
        try handle.write(contentsOf: Data([0x0A]))
    }

    public func appendMany<T: Encodable>(_ values: [T]) throws {
        for value in values {
            try append(value)
        }
    }

    public func sync() throws {
        try fileHandle?.synchronize()
    }

    public func close() throws {
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
    }

    public nonisolated var fileURL: URL { url }
}

public enum JsonlReader {
    public static func readAll<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var out: [T] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines {
            let lineData = Data(line)
            let value = try decoder.decode(T.self, from: lineData)
            out.append(value)
        }
        return out
    }
}
