import Foundation

/// Persistence policy for `ModeRegistry`.
///
/// `.ephemeral` keeps custom modes in memory only — used for tests and for the
/// stdio MCP child process. `.sqlite(db)` writes custom modes to the
/// `dictation_modes` table (added in `DictationSchema` migration v15).
public enum ModeRegistryPersistence: Sendable {
    case ephemeral
    case sqlite(SqliteDatabase)
}

/// Owner of the in-memory `[UUID: Mode]` table. Loads built-ins from
/// `Bundle.module/modes-builtin.json` on `bootstrap()` and merges any persisted
/// custom modes from the SQLite back-end.
///
/// Built-in modes (`Mode.isBuiltIn == true`) are immutable. CRUD operations
/// targeting a built-in throw `TraceError.configInvalid`.
public actor ModeRegistry {
    private var modes: [UUID: Mode] = [:]
    private let persistence: ModeRegistryPersistence
    private let bundle: Bundle
    private var bootstrapped = false

    public init(persistence: ModeRegistryPersistence) {
        self.persistence = persistence
        self.bundle = .module
    }

    init(persistence: ModeRegistryPersistence, bundle: Bundle) {
        self.persistence = persistence
        self.bundle = bundle
    }

    /// Idempotent.
    ///
    /// Repeated calls are no-ops.
    public func bootstrap() async throws {
        guard !bootstrapped else { return }
        try loadBuiltins()
        if case .sqlite(let db) = persistence {
            try await loadCustomModes(from: db)
        }
        bootstrapped = true
        Loggers.dictation.info("ModeRegistry bootstrapped with \(self.modes.count, privacy: .public) modes")
    }

    public func all() -> [Mode] {
        Array(modes.values)
    }

    public func mode(id: UUID) -> Mode? {
        modes[id]
    }

    public func mode(named: String) -> Mode? {
        modes.values.first(where: { $0.name == named })
    }

    public func add(_ mode: Mode) async throws {
        guard modes[mode.id] == nil else {
            throw TraceError.configInvalid(
                field: "Mode.id",
                reason: "Mode with id \(mode.id) already exists"
            )
        }
        if mode.isBuiltIn {
            throw TraceError.configInvalid(
                field: "Mode.isBuiltIn",
                reason: "Cannot add a Mode flagged as built-in via add(); clone via Mode.cloned(asCustomName:) first."
            )
        }
        modes[mode.id] = mode
        if case .sqlite(let db) = persistence {
            try await persistCustom(mode, into: db)
        }
    }

    public func update(_ mode: Mode) async throws {
        guard let existing = modes[mode.id] else {
            throw TraceError.configInvalid(
                field: "Mode.id",
                reason: "Mode with id \(mode.id) not found"
            )
        }
        if existing.isBuiltIn {
            throw TraceError.configInvalid(
                field: "Mode.isBuiltIn",
                reason:
                    "Cannot update a built-in mode. Clone via Mode.cloned(asCustomName:) and persist the clone instead."
            )
        }
        modes[mode.id] = mode
        if case .sqlite(let db) = persistence {
            try await persistCustom(mode, into: db)
        }
    }

    public func remove(id: UUID) async throws {
        guard let existing = modes[id] else { return }
        if existing.isBuiltIn {
            throw TraceError.configInvalid(
                field: "Mode.isBuiltIn",
                reason: "Cannot remove a built-in mode."
            )
        }
        modes.removeValue(forKey: id)
        if case .sqlite(let db) = persistence {
            try await deleteCustom(id: id, from: db)
        }
    }

    /// Test-only insertion that bypasses the `isBuiltIn` guard so unit tests
    /// can construct controlled mode sets without the bundle round trip.
    func testInsert(_ mode: Mode) {
        modes[mode.id] = mode
    }

    private func loadBuiltins() throws {
        // SwiftPM's `.copy("Dictation/ModeResources")` puts the directory at
        // either `ModeResources/modes-builtin.json` or directly at the bundle
        // root depending on Xcode vs `swift build` packaging. Try both.
        let candidates: [URL?] = [
            bundle.url(forResource: "modes-builtin", withExtension: "json", subdirectory: "ModeResources"),
            bundle.url(forResource: "modes-builtin", withExtension: "json"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/ModeResources/modes-builtin.json"),
            bundle.resourceURL?.appendingPathComponent("ModeResources/modes-builtin.json"),
            bundle.resourceURL?.appendingPathComponent("modes-builtin.json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw TraceError.storageFailed(
                reason: "modes-builtin.json missing from bundle (\(bundle.bundlePath))"
            )
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let raw: [BuiltinModeJSON]
        do {
            raw = try decoder.decode([BuiltinModeJSON].self, from: data)
        } catch {
            throw TraceError.configInvalid(
                field: "modes-builtin.json",
                reason: "decode failed: \(error.localizedDescription)"
            )
        }
        let now = Date().timeIntervalSince1970
        for r in raw {
            let mode = Mode(
                id: r.id,
                name: r.name,
                bundleIDRegex: r.bundleIDRegex,
                hotkeyOverride: r.hotkeyOverride,
                modelRouteOverride: r.modelRouteOverride,
                systemPrompt: r.systemPrompt,
                insertBehavior: r.insertBehavior,
                afterInsertBehavior: r.afterInsertBehavior,
                isBuiltIn: true,
                createdAt: now,
                updatedAt: now
            )
            modes[mode.id] = mode
        }
    }

    private func loadCustomModes(from db: SqliteDatabase) async throws {
        let rows = try await db.withStatement(
            sql: "SELECT id, payload_json FROM dictation_modes ORDER BY updated_at DESC"
        ) { stmt -> [String] in
            var out: [String] = []
            while case .row = try stmt.step() {
                if let json = stmt.columnText(at: 1) { out.append(json) }
            }
            return out
        }
        let decoder = JSONDecoder()
        for json in rows {
            guard let data = json.data(using: .utf8) else { continue }
            do {
                let mode = try decoder.decode(Mode.self, from: data)
                if !mode.isBuiltIn {
                    modes[mode.id] = mode
                }
            } catch {
                Loggers.dictation.warning(
                    "Skipped malformed custom mode row: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func persistCustom(_ mode: Mode, into db: SqliteDatabase) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(mode)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TraceError.storageFailed(reason: "mode JSON encode produced non-utf8 bytes")
        }
        let idText = mode.id.uuidString
        let updatedAt = Int64(mode.updatedAt)
        try await db.withStatement(
            sql: """
                INSERT INTO dictation_modes (id, payload_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json, updated_at=excluded.updated_at
                """
        ) { stmt in
            try stmt.bind(text: idText, at: 1)
            try stmt.bind(text: json, at: 2)
            try stmt.bind(int64: updatedAt, at: 3)
            _ = try stmt.step()
        }
    }

    private func deleteCustom(id: UUID, from db: SqliteDatabase) async throws {
        let idText = id.uuidString
        try await db.withStatement(sql: "DELETE FROM dictation_modes WHERE id = ?") { stmt in
            try stmt.bind(text: idText, at: 1)
            _ = try stmt.step()
        }
    }

    private struct BuiltinModeJSON: Codable {
        let id: UUID
        let name: String
        let bundleIDRegex: String
        let hotkeyOverride: String?
        let modelRouteOverride: LLMRoute?
        let systemPrompt: String
        let insertBehavior: InsertBehavior
        let afterInsertBehavior: AfterInsertBehavior
    }
}
