import AppKit
import Foundation

public struct FrontmostApp: Sendable, Hashable, Codable {
    public let bundleIdentifier: String
    public let localizedName: String?
    public let executableURL: URL?
    public init(bundleIdentifier: String, localizedName: String?, executableURL: URL?) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.executableURL = executableURL
    }
}

public protocol FrontmostAppSourcing: Sendable {
    func currentSequenceForTesting() async -> [FrontmostApp]
}

public actor FrontmostAppMonitor {
    private let source: any FrontmostAppSourcing
    private var lastBundleID: String?

    public init(source: any FrontmostAppSourcing = NSWorkspaceFrontmostSource()) {
        self.source = source
    }

    public func collectOnePassForTesting() async -> [FrontmostApp] {
        var out: [FrontmostApp] = []
        for app in await source.currentSequenceForTesting() {
            guard app.bundleIdentifier != lastBundleID else { continue }
            lastBundleID = app.bundleIdentifier
            out.append(app)
        }
        return out
    }
}

public struct NSWorkspaceFrontmostSource: FrontmostAppSourcing {
    public init() {}
    public func currentSequenceForTesting() async -> [FrontmostApp] {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        else { return [] }
        return [
            FrontmostApp(
                bundleIdentifier: bundleID,
                localizedName: app.localizedName,
                executableURL: app.executableURL)
        ]
    }
}
