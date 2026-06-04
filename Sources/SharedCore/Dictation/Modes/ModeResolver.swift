import Foundation

/// Resolves the best `Mode` for the currently frontmost application.
///
/// Matching policy:
/// 1. Iterate every mode whose compiled `bundleIDRegex` matches the supplied
///    bundle identifier (a full match is required via `NSRegularExpression`'s
///    `firstMatch` over the entire string range).
/// 2. Sort matches by `updatedAt` descending — the most-recently-edited mode
///    wins on ties.
/// 3. Return the first one. The Default mode (`bundleIDRegex == ".*"`) is the
///    catch-all fallback; it always loses to a more-specific match.
///
/// If no mode matches and there is no catch-all, the resolver throws
/// `TraceError.configInvalid`. The Default built-in keeps that path closed
/// in production.
public struct ModeResolver: Sendable {
    private let registry: ModeRegistry
    private let bundleIDProvider: @Sendable () -> String?
    /// Reads the frontmost browser's active-tab URL for per-website matching
    /// (BAS-5). `nil` disables URL matching entirely (modes resolve on bundle ID
    /// only — the prior behavior).
    private let browserTabReader: (any BrowserTabReading)?

    public init(
        registry: ModeRegistry,
        bundleIDProvider: @escaping @Sendable () -> String?,
        browserTabReader: (any BrowserTabReading)? = nil
    ) {
        self.registry = registry
        self.bundleIDProvider = bundleIDProvider
        self.browserTabReader = browserTabReader
    }

    public func resolveCurrent() async throws -> Mode {
        let bundleID = bundleIDProvider()
        let candidates = await registry.all()

        if let bundleID, !bundleID.isEmpty {
            // Per-website modes (BAS-5): when the frontmost app is a browser, the
            // active tab's URL can pick a more specific mode than the browser's
            // bundle ID (which is identical for every site). A URL match outranks
            // any bundle-ID match; ties break on most-recently-edited.
            if MeetingAppCatalog.isBrowser(bundleID),
                let reader = browserTabReader,
                let tab = await reader.activeBrowserTab(frontmostBundleID: bundleID)
            {
                var urlMatches: [Mode] = []
                for mode in candidates {
                    // `try?` not `try`: a single mode with an invalid `urlRegex`
                    // (free-text user field, no live validation) must skip itself,
                    // not abort resolution for EVERY mode and leave dictation with
                    // no mode whenever a browser is frontmost. `try?` flattens the
                    // function's `NSRegularExpression?` to a single optional (nil =
                    // either not URL-scoped, or a bad pattern → skip this mode).
                    guard let regex = try? mode.compiledURLRegex() else { continue }
                    let range = NSRange(tab.url.startIndex..., in: tab.url)
                    if regex.firstMatch(in: tab.url, options: [], range: range) != nil {
                        urlMatches.append(mode)
                    }
                }
                urlMatches.sort { $0.updatedAt > $1.updatedAt }
                if let best = urlMatches.first {
                    return best
                }
            }

            var specific: [Mode] = []
            var catchAll: [Mode] = []
            for mode in candidates {
                let regex = try mode.compiledBundleIDRegex()
                let range = NSRange(bundleID.startIndex..., in: bundleID)
                guard regex.firstMatch(in: bundleID, options: [], range: range) != nil else { continue }
                if mode.bundleIDRegex == ".*" {
                    catchAll.append(mode)
                } else {
                    specific.append(mode)
                }
            }
            specific.sort { $0.updatedAt > $1.updatedAt }
            if let best = specific.first {
                return best
            }
            catchAll.sort { $0.updatedAt > $1.updatedAt }
            if let best = catchAll.first {
                return best
            }
        }

        if let fallback = candidates.first(where: { $0.bundleIDRegex == ".*" }) {
            return fallback
        }

        throw TraceError.configInvalid(
            field: "ModeResolver",
            reason: "no mode matched bundle id \(bundleID ?? "<nil>") and no catch-all is registered"
        )
    }
}
