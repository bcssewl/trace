import Foundation

public struct SecurityScopedBookmark: Sendable, Hashable {
    public let bookmarkData: Data
    public let originalPath: String

    public init(bookmarkData: Data, originalPath: String) {
        self.bookmarkData = bookmarkData
        self.originalPath = originalPath
    }

    public static func make(from url: URL) throws -> SecurityScopedBookmark {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return SecurityScopedBookmark(bookmarkData: data, originalPath: url.path)
    }

    public func resolve() throws -> ResolvedFolder {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw TraceError.storageFailed(reason: "Could not start security-scoped access for \(url.path)")
        }
        return ResolvedFolder(url: url, isStale: stale)
    }
}

public final class ResolvedFolder: Sendable {
    public let url: URL
    public let isStale: Bool

    init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}

public struct MarkdownFolderConfig: Sendable, Codable, Hashable {
    public let bookmarkData: Data?
    public let displayPath: String

    public init(bookmarkData: Data? = nil, displayPath: String) {
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
    }

    public static func makeDefault() -> MarkdownFolderConfig {
        let docs =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        let folder = docs.appendingPathComponent("Trace", isDirectory: true)
        return MarkdownFolderConfig(displayPath: folder.path)
    }

    public func resolvedURL() throws -> URL {
        if let data = bookmarkData {
            let bookmark = SecurityScopedBookmark(bookmarkData: data, originalPath: displayPath)
            return try bookmark.resolve().url
        }
        return URL(fileURLWithPath: displayPath)
    }
}
