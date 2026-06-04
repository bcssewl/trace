import XCTest

@testable import SharedCore

final class InsertBehaviorTests: XCTestCase {
    func testAllCasesAreCodable() throws {
        let cases: [InsertBehavior] = [.pasteAtCursor, .replaceSelection, .appendToBuffer]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        for c in cases {
            let data = try enc.encode(c)
            let back = try dec.decode(InsertBehavior.self, from: data)
            XCTAssertEqual(c, back)
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(InsertBehavior.pasteAtCursor.rawValue, "pasteAtCursor")
        XCTAssertEqual(InsertBehavior.replaceSelection.rawValue, "replaceSelection")
        XCTAssertEqual(InsertBehavior.appendToBuffer.rawValue, "appendToBuffer")
    }
}

final class AfterInsertBehaviorTests: XCTestCase {
    func testKeepOpenRoundTrip() throws {
        let data = try JSONEncoder().encode(AfterInsertBehavior.keepOpen)
        let back = try JSONDecoder().decode(AfterInsertBehavior.self, from: data)
        XCTAssertEqual(back, .keepOpen)
    }

    func testCloseHudRoundTrip() throws {
        let data = try JSONEncoder().encode(AfterInsertBehavior.closeHud)
        let back = try JSONDecoder().decode(AfterInsertBehavior.self, from: data)
        XCTAssertEqual(back, .closeHud)
    }

    func testCloseHudAfterDelayRoundTrip() throws {
        let value = AfterInsertBehavior.closeHudAfterDelay(seconds: 1.5)
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(AfterInsertBehavior.self, from: data)
        XCTAssertEqual(back, value)
    }

    func testUnknownKindIsRejected() {
        let json = #"{"kind":"banana"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AfterInsertBehavior.self, from: json))
    }
}

final class ModeCodableTests: XCTestCase {
    func testRoundTripPreservesEveryField() throws {
        let mode = Mode(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000abcd")!,
            name: "Default",
            bundleIDRegex: ".*",
            hotkeyOverride: nil,
            modelRouteOverride: nil,
            systemPrompt: "Clean up the text.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen,
            isBuiltIn: true,
            createdAt: 1_748_332_800,
            updatedAt: 1_748_332_800
        )
        let data = try JSONEncoder().encode(mode)
        let back = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(back, mode)
    }

    func testRegexCompilesOnDemand() throws {
        let mode = Mode.makeBuiltIn(
            name: "Email",
            bundleIDRegex: "^com\\.apple\\.mail$",
            systemPrompt: "Email tone.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .closeHud
        )
        let regex = try mode.compiledBundleIDRegex()
        let bundleID = "com.apple.mail"
        let range = NSRange(bundleID.startIndex..., in: bundleID)
        XCTAssertNotNil(regex.firstMatch(in: bundleID, range: range))
    }

    func testInvalidRegexThrowsConfigError() {
        let mode = Mode.makeBuiltIn(
            name: "Bad",
            bundleIDRegex: "[a-z",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        XCTAssertThrowsError(try mode.compiledBundleIDRegex()) { error in
            guard case TraceError.configInvalid(let field, _) = error else {
                XCTFail("expected configInvalid, got \(error)")
                return
            }
            XCTAssertEqual(field, "Mode.bundleIDRegex")
        }
    }

    func testCustomModeIsNotBuiltIn() {
        let mode = Mode.makeCustom(
            name: "Custom",
            bundleIDRegex: ".*",
            systemPrompt: "test",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        XCTAssertFalse(mode.isBuiltIn)
    }

    func testTouchUpdatesTimestamp() {
        var mode = Mode.makeCustom(
            name: "Custom",
            bundleIDRegex: ".*",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        let before = mode.updatedAt
        mode.touch(at: before + 10)
        XCTAssertEqual(mode.updatedAt, before + 10)
    }

    func testClonedIsCustomWithNewID() {
        let built = Mode.makeBuiltIn(
            name: "Default",
            bundleIDRegex: ".*",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        let clone = built.cloned(asCustomName: "Default (mine)")
        XCTAssertNotEqual(clone.id, built.id)
        XCTAssertFalse(clone.isBuiltIn)
        XCTAssertEqual(clone.systemPrompt, built.systemPrompt)
    }
}

final class ModesBuiltinBundlingTests: XCTestCase {
    func testBuiltInModesJsonIsBundled() {
        let url = Bundle.module.url(
            forResource: "modes-builtin",
            withExtension: "json",
            subdirectory: "ModeResources"
        )
        XCTAssertNotNil(url, "modes-builtin.json must be bundled under ModeResources")
    }

    func testBundledFileDecodesIntoFiveModes() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "modes-builtin",
                withExtension: "json",
                subdirectory: "ModeResources"
            )
        )
        let data = try Data(contentsOf: url)
        struct Row: Decodable {
            let id: UUID
            let name: String
            let bundleIDRegex: String
            let hotkeyOverride: String?
            let modelRouteOverride: LLMRoute?
            let systemPrompt: String
            let insertBehavior: InsertBehavior
            let afterInsertBehavior: AfterInsertBehavior
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        XCTAssertEqual(rows.count, 5)
        let names = Set(rows.map(\.name))
        XCTAssertEqual(names, ["Default", "Email", "Slack", "Code", "Note"])
    }
}

final class ModeRegistryTests: XCTestCase {
    func testBootstrapLoadsFiveBuiltins() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let all = await registry.all()
        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(all.allSatisfy(\.isBuiltIn))
        let names = Set(all.map(\.name))
        XCTAssertEqual(names, ["Default", "Email", "Slack", "Code", "Note"])
    }

    func testBootstrapIsIdempotent() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        try await registry.bootstrap()
        let all = await registry.all()
        XCTAssertEqual(all.count, 5)
    }

    func testAddCustomModeAppears() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let custom = Mode.makeCustom(
            name: "Twitter",
            bundleIDRegex: "^com\\.twitter\\.",
            systemPrompt: "Concise tweet style.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .closeHud
        )
        try await registry.add(custom)
        let back = await registry.mode(id: custom.id)
        XCTAssertEqual(back?.id, custom.id)
    }

    func testAddRejectsBuiltInFlaggedMode() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let bogus = Mode.makeBuiltIn(
            name: "Synthetic",
            bundleIDRegex: "^x$",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        do {
            try await registry.add(bogus)
            XCTFail("add of built-in should throw")
        } catch let err as TraceError {
            guard case .configInvalid(let field, _) = err else {
                XCTFail("wrong error: \(err)")
                return
            }
            XCTAssertEqual(field, "Mode.isBuiltIn")
        }
    }

    func testUpdateBuiltInThrows() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let all = await registry.all()
        guard var def = all.first(where: { $0.name == "Default" }) else {
            return XCTFail("Default missing")
        }
        def.systemPrompt = "tampered"
        do {
            try await registry.update(def)
            XCTFail("update of built-in should throw")
        } catch let err as TraceError {
            guard case .configInvalid(let field, _) = err else {
                XCTFail("wrong error: \(err)")
                return
            }
            XCTAssertEqual(field, "Mode.isBuiltIn")
        }
    }

    func testCloneThenUpdateRoundTrips() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let all = await registry.all()
        guard let def = all.first(where: { $0.name == "Default" }) else {
            return XCTFail("Default missing")
        }
        var clone = def.cloned(asCustomName: "Default (mine)")
        try await registry.add(clone)
        clone.systemPrompt = "edited"
        clone.touch(at: clone.updatedAt + 1)
        try await registry.update(clone)
        let back = await registry.mode(id: clone.id)
        XCTAssertEqual(back?.systemPrompt, "edited")
    }

    func testRemoveCustomMode() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let custom = Mode.makeCustom(
            name: "Temp",
            bundleIDRegex: ".*",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        try await registry.add(custom)
        try await registry.remove(id: custom.id)
        let back = await registry.mode(id: custom.id)
        XCTAssertNil(back)
    }

    func testRemoveBuiltInThrows() async throws {
        let registry = ModeRegistry(persistence: .ephemeral)
        try await registry.bootstrap()
        let all = await registry.all()
        guard let built = all.first(where: { $0.isBuiltIn }) else {
            return XCTFail("no built-in available")
        }
        do {
            try await registry.remove(id: built.id)
            XCTFail("remove of built-in should throw")
        } catch let err as TraceError {
            guard case .configInvalid = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        }
    }

    func testSqlitePersistenceRoundTrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mode-registry-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("idx.sqlite")
        let db = try await SqliteDatabase.open(at: dbURL)
        try await SchemaV1.bootstrap(database: db)

        let firstRegistry = ModeRegistry(persistence: .sqlite(db))
        try await firstRegistry.bootstrap()
        let custom = Mode.makeCustom(
            name: "Cursor",
            bundleIDRegex: "^com\\.todesktop\\.230313mzl4w4u92$",
            systemPrompt: "code commit body",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        try await firstRegistry.add(custom)

        let secondRegistry = ModeRegistry(persistence: .sqlite(db))
        try await secondRegistry.bootstrap()
        let back = await secondRegistry.mode(id: custom.id)
        XCTAssertEqual(back?.systemPrompt, "code commit body")

        try await db.close()
    }
}

final class ModeResolverTests: XCTestCase {
    private func registry(with modes: [Mode]) async -> ModeRegistry {
        let registry = ModeRegistry(persistence: .ephemeral)
        for mode in modes {
            await registry.testInsert(mode)
        }
        return registry
    }

    func testFrontmostMailResolvesToEmail() async throws {
        let email = Mode.makeBuiltIn(
            name: "Email",
            bundleIDRegex: "^com\\.apple\\.mail$",
            systemPrompt: "Email tone.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .closeHud,
            now: 100
        )
        let def = Mode.makeBuiltIn(
            name: "Default",
            bundleIDRegex: ".*",
            systemPrompt: "Default cleanup.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen,
            now: 90
        )
        let reg = await registry(with: [email, def])
        let resolver = ModeResolver(registry: reg, bundleIDProvider: { "com.apple.mail" })
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Email")
    }

    func testNilBundleIDFallsBackToDefault() async throws {
        let def = Mode.makeBuiltIn(
            name: "Default",
            bundleIDRegex: ".*",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        let reg = await registry(with: [def])
        let resolver = ModeResolver(registry: reg, bundleIDProvider: { nil })
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Default")
    }

    func testMostRecentlyEditedWinsOnTie() async throws {
        let older = Mode.makeBuiltIn(
            name: "Email_v1",
            bundleIDRegex: "^com\\.apple\\.mail$",
            systemPrompt: "v1",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen,
            now: 100
        )
        let newer = Mode.makeBuiltIn(
            name: "Email_v2",
            bundleIDRegex: "^com\\.apple\\.mail$",
            systemPrompt: "v2",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen,
            now: 200
        )
        let reg = await registry(with: [older, newer])
        let resolver = ModeResolver(registry: reg, bundleIDProvider: { "com.apple.mail" })
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Email_v2")
    }

    func testNoMatchAndNoCatchAllThrows() async {
        let strict = Mode.makeBuiltIn(
            name: "Strict",
            bundleIDRegex: "^com\\.apple\\.notes$",
            systemPrompt: "x",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        let reg = await registry(with: [strict])
        let resolver = ModeResolver(registry: reg, bundleIDProvider: { "com.apple.mail" })
        do {
            _ = try await resolver.resolveCurrent()
            XCTFail("expected throw")
        } catch let err as TraceError {
            guard case .configInvalid = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFrontmostSlackResolvesToSlack() async throws {
        let slack = Mode.makeBuiltIn(
            name: "Slack",
            bundleIDRegex: "^com\\.tinyspeck\\.slackmacgap$",
            systemPrompt: "Casual.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .closeHud
        )
        let def = Mode.makeBuiltIn(
            name: "Default",
            bundleIDRegex: ".*",
            systemPrompt: "default",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .keepOpen
        )
        let reg = await registry(with: [slack, def])
        let resolver = ModeResolver(registry: reg, bundleIDProvider: { "com.tinyspeck.slackmacgap" })
        let resolved = try await resolver.resolveCurrent()
        XCTAssertEqual(resolved.name, "Slack")
    }
}
