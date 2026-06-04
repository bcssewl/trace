import Foundation

public struct DatabasePaths: Sendable {
    public let applicationName: String

    public init(applicationName: String = "Trace") {
        self.applicationName = applicationName
    }

    public func indexDatabaseURL() throws -> URL {
        let supportDir = try applicationSupportDirectory()
        return supportDir.appendingPathComponent("index.sqlite", isDirectory: false)
    }

    public func applicationSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = appSupport.appendingPathComponent(applicationName, isDirectory: true)
        if !fm.fileExists(atPath: appDir.path) {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir
    }

    public func audioArchiveDirectory() throws -> URL {
        let supportDir = try applicationSupportDirectory()
        let archive = supportDir.appendingPathComponent("audio-archive", isDirectory: true)
        if !FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        }
        return archive
    }
}
