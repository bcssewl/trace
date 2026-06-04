import Foundation

public struct MarkdownStore: Sendable {
    private let folderConfig: MarkdownFolderConfig

    public init(folderConfig: MarkdownFolderConfig) {
        self.folderConfig = folderConfig
    }

    public func rootURL() throws -> URL {
        let root = try folderConfig.resolvedURL()
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    public func layout(projectFolderName: String, sessionId: String) throws -> SessionLayout {
        let root = try rootURL()
        return SessionLayout(root: root, projectFolderName: projectFolderName, sessionId: sessionId)
    }

    public func writeNotes(_ markdown: String, to layout: SessionLayout) throws {
        try layout.createDirectories()
        try markdown.write(to: layout.notesURL, atomically: true, encoding: .utf8)
    }

    public func readNotes(at layout: SessionLayout) throws -> String {
        if !FileManager.default.fileExists(atPath: layout.notesURL.path) {
            return ""
        }
        return try String(contentsOf: layout.notesURL, encoding: .utf8)
    }

    public func writeSessionJson(_ metadata: SessionMetadata, to layout: SessionLayout) throws {
        try layout.createDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(metadata)
        try data.write(to: layout.sessionJsonURL, options: .atomic)
    }

    public func readSessionJson(at layout: SessionLayout) throws -> SessionMetadata {
        let data = try Data(contentsOf: layout.sessionJsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionMetadata.self, from: data)
    }

    public func writeNotesMeta(_ json: Data, to layout: SessionLayout) throws {
        try layout.createDirectories()
        try json.write(to: layout.notesMetaURL, options: .atomic)
    }

    public func listProjectFolders() throws -> [String] {
        let root = try rootURL()
        let contents = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func listSessions(inProject projectFolderName: String) throws -> [String] {
        let root = try rootURL()
        let project = root.appendingPathComponent(projectFolderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.isDirectoryKey])
        return
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }
}
