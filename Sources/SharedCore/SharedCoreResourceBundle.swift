import Foundation

enum SharedCoreResourceBundle {
    private static let bundleName = "Trace_SharedCore.bundle"

    static let bundle: Bundle = {
        let main = Bundle.main
        let candidates: [URL?] = [
            main.resourceURL?.appendingPathComponent(bundleName),
            main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
            main.bundleURL.appendingPathComponent(bundleName),
            main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName),
        ]

        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        if let bundle = localBuildBundle() {
            return bundle
        }

        return main
    }()

    private static func localBuildBundle() -> Bundle? {
        guard let repoRoot = repoRootFromSourcePath() else { return nil }
        let buildRoot = repoRoot.appendingPathComponent(".build")
        let likelyPaths = [
            buildRoot.appendingPathComponent("arm64-apple-macosx/release/\(bundleName)"),
            buildRoot.appendingPathComponent("arm64-apple-macosx/debug/\(bundleName)"),
        ]

        for url in likelyPaths {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        guard let enumerator = FileManager.default.enumerator(at: buildRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == bundleName {
            return Bundle(url: url)
        }
        return nil
    }

    private static func repoRootFromSourcePath() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
