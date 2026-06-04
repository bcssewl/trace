import SharedCore
import SwiftUI

/// Functional editor for dictation *modes* — the per-application cleanup rules
/// whose `systemPrompt` instructs the cleanup LLM how to reformat transcribed
/// text (Email mode → email style, Slack → casual one-liners, …).
///
/// Master-detail: the left column lists every mode (built-ins first, then custom
/// by name); the right pane edits the selected one. Built-in modes are read-only
/// and must be duplicated to a custom mode before editing. Custom modes persist
/// to SQLite via `ModeRegistry`; if no database is bootstrapped the registry
/// runs ephemerally (built-ins still show, custom edits won't survive relaunch).
@MainActor
public struct DictationModesSettingsView: View {
    @Environment(\.brutalistPalette) private var palette

    /// The actor that owns the modes.
    ///
    /// Created once on first appear and reused
    /// for every edit so we never lose the loaded/ephemeral state.
    @State private var registry: ModeRegistry?
    /// The current modes, already sorted for display.
    @State private var modes: [Mode] = []
    /// Selection is tracked by id (not the whole `Mode`) so a reload that
    /// produces a fresh array element keeps the same row selected.
    @State private var selectedID: Mode.ID?

    // Staged edits for the selected CUSTOM mode. Synced from the selected mode
    // on selection change and after reloads; written back to the registry on
    // "Save changes".
    @State private var editName: String = ""
    @State private var editRegex: String = ""
    @State private var editURLRegex: String = ""
    @State private var editPrompt: String = ""
    @State private var editInsert: InsertBehavior = .pasteAtCursor

    @State private var loaded = false
    @State private var persists = true
    @State private var errorText: String?

    public init() {}

    private var selectedMode: Mode? {
        guard let selectedID else { return nil }
        return modes.first(where: { $0.id == selectedID })
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            modeList
                .frame(width: 280)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(palette.bgTertiary.color)
                .overlay(
                    Rectangle().fill(palette.border.color).frame(width: 1),
                    alignment: .trailing
                )
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await loadInitial()
        }
        .onChange(of: selectedID) { _, _ in
            syncEditFields()
        }
    }

    // MARK: - Left column

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !loaded {
                        Text("Loading modes…")
                            .font(BrutalistTypography.mono10)
                            .foregroundStyle(palette.fgMuted.color)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    } else if modes.isEmpty {
                        Text("No modes found")
                            .font(BrutalistTypography.mono10)
                            .foregroundStyle(palette.fgMuted.color)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(modes) { mode in
                            modeRow(mode)
                        }
                    }
                }
                .padding(.top, 6)
            }
            Rectangle().fill(palette.border.color).frame(height: 1)
            if !persists {
                Text("Storage isn’t set up, so custom modes won’t be saved after you quit.")
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            HStack {
                BrutalistButton("+ New mode", kind: .ghost) {
                    addNewMode()
                }
                Spacer()
            }
            .padding(BrutalistMetrics.space3)
        }
    }

    private func modeRow(_ mode: Mode) -> some View {
        let active = mode.id == selectedID
        return Button {
            selectedID = mode.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(active ? palette.primary.color : palette.accentBg.color)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mode.name)
                            .font(BrutalistTypography.uiLabel)
                            .foregroundStyle(active ? palette.fg.color : palette.fgSidebar.color)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(mode.isBuiltIn ? "Built-in" : "Custom")
                            .font(BrutalistTypography.mono10)
                            .foregroundStyle(palette.fgMuted.color)
                    }
                    Text(appLabel(for: mode.bundleIDRegex))
                        .font(BrutalistTypography.mono10)
                        .foregroundStyle(palette.fgMuted.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(active ? palette.secondary.color : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right editor pane

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let mode = selectedMode {
                    editorHeader(mode)
                    if let errorText {
                        errorBanner(errorText)
                    }
                    if mode.isBuiltIn {
                        builtInEditor(mode)
                    } else {
                        customEditor(mode)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.bottom, 32)
        }
    }

    private func editorHeader(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(mode.isBuiltIn ? mode.name : (editName.isEmpty ? mode.name : editName))
                    .font(BrutalistTypography.title)
                    .foregroundStyle(palette.fg.color)
                Text(mode.isBuiltIn ? "Built-in" : "Custom")
                    .font(BrutalistTypography.captionEmphasis)
                    .foregroundStyle(palette.primary.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.primary.color.opacity(0.12))
                    )
                Spacer()
            }
            Text("How Trace tidies up your dictation when you’re using this app.")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: 1),
            alignment: .bottom
        )
    }

    // Read-only view of a built-in mode + the duplicate action.
    @ViewBuilder
    private func builtInEditor(_ mode: Mode) -> some View {
        SettingsGroup("Mode") {
            fieldRow(title: "Name", hint: nil) {
                TextField("", text: .constant(mode.name))
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.mono11)
                    .disabled(true)
            }
            fieldRow(
                title: "Use this mode in",
                hint:
                    "Which apps this mode applies to, matched by app ID. For example, ^com\\.apple\\.mail$ for Mail, or .* for every app."
            ) {
                TextField("", text: .constant(mode.bundleIDRegex))
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.mono11)
                    .disabled(true)
            }
            fieldRow(title: "Where the text goes", hint: nil) {
                Text(label(for: mode.insertBehavior))
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fgMuted.color)
            }
        }

        promptGroup(text: .constant(mode.systemPrompt), editable: false)

        VStack(alignment: .leading, spacing: 12) {
            Text("Built-in modes can’t be edited. Make a copy to change it.")
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
            HStack {
                BrutalistButton("Duplicate & edit", kind: .primary) {
                    duplicate(mode)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
    }

    // Editable view of a custom mode bound to the staged @State fields.
    @ViewBuilder
    private func customEditor(_ mode: Mode) -> some View {
        SettingsGroup("Mode") {
            fieldRow(title: "Name", hint: nil) {
                TextField("Mode name", text: $editName)
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fg.color)
            }
            fieldRow(
                title: "Use this mode in",
                hint:
                    "Which apps this mode applies to, matched by app ID. For example, ^com\\.apple\\.mail$ for Mail, or .* for every app."
            ) {
                TextField(".*", text: $editRegex)
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fg.color)
            }
            fieldRow(
                title: "Or a specific website",
                hint:
                    "Optional. If the app above is a browser, this matches the site in the active tab and takes priority over the app. For example, mail\\.google\\.com."
            ) {
                TextField("mail\\.google\\.com", text: $editURLRegex)
                    .textFieldStyle(.plain)
                    .font(BrutalistTypography.mono11)
                    .foregroundStyle(palette.fg.color)
            }
            fieldRow(title: "Where the text goes", hint: "How the tidied-up text ends up in the app.") {
                Picker("", selection: $editInsert) {
                    ForEach(InsertBehavior.allCases, id: \.self) { behavior in
                        Text(label(for: behavior)).tag(behavior)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }

        promptGroup(text: $editPrompt, editable: true)

        HStack(spacing: 10) {
            BrutalistButton("Save changes", kind: .primary) {
                save(mode)
            }
            BrutalistButton("Delete", kind: .ghost) {
                delete(mode)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
    }

    // The system-prompt editor — the most important field.
    private func promptGroup(text: Binding<String>, editable: Bool) -> some View {
        SettingsGroup("Instructions", tag: "Tidy-up") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: text)
                    .font(BrutalistTypography.mono13)
                    .foregroundStyle(palette.fg.color)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(palette.background.color)
                    .overlay(
                        Rectangle().stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline)
                    )
                    .disabled(!editable)
                    .opacity(editable ? 1 : 0.7)
                Text(
                    "Tell Trace how to clean up your dictation in this app. Keep it to reshaping the words — it should rework your text, never answer it."
                )
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.fgMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 80)
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(palette.fgMuted.color)
            Text("Choose a mode to edit")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text(
                "Modes tell Trace how to tidy up your dictation in each app. Pick one on the left, or create a new one."
            )
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.fgMuted.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(BrutalistTypography.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(palette.primary.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.primary.color.opacity(0.10))
        .overlay(
            Rectangle().stroke(palette.primary.color.opacity(0.4), lineWidth: BrutalistMetrics.hairline)
        )
        .padding(.horizontal, 32)
        .padding(.top, 14)
    }

    // A label/hint row that hosts an editable control (mirrors SettingsRow's
    // spacing but lets the trailing control stretch for text fields).
    private func fieldRow<Trailing: View>(
        title: String,
        hint: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrutalistTypography.label)
                .foregroundStyle(palette.fg.color)
            trailing()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.background.color)
                .overlay(
                    Rectangle().stroke(palette.border.color, lineWidth: BrutalistMetrics.hairline)
                )
            if let hint {
                Text(hint)
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.borderSoft.color)
                .frame(height: BrutalistMetrics.hairline)
                .padding(.leading, 14)
        }
    }

    // MARK: - Loading

    private func loadInitial() async {
        guard !loaded else { return }
        let db = BootContext.current?.database
        persists = db != nil
        let reg = ModeRegistry(persistence: db.map { .sqlite($0) } ?? .ephemeral)
        registry = reg
        do {
            try await reg.bootstrap()
            let all = await reg.all()
            applyModes(all, preferSelection: all.first(where: { $0.name == "Default" })?.id ?? all.first?.id)
        } catch {
            errorText = "Couldn't load modes: \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Re-reads modes from the registry and refreshes the sorted list, keeping
    /// (or moving) the selection as requested.
    private func reload(select newSelection: Mode.ID? = nil) async {
        guard let registry else { return }
        let all = await registry.all()
        let keep = newSelection ?? selectedID
        applyModes(all, preferSelection: keep)
    }

    private func applyModes(_ all: [Mode], preferSelection: Mode.ID?) {
        modes = sortedModes(all)
        if let preferSelection, modes.contains(where: { $0.id == preferSelection }) {
            selectedID = preferSelection
        } else if !modes.contains(where: { $0.id == selectedID }) {
            selectedID = modes.first?.id
        }
        syncEditFields()
    }

    /// Built-ins first ("Default" pinned to the very top), then custom by name.
    private func sortedModes(_ all: [Mode]) -> [Mode] {
        all.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn && !b.isBuiltIn }
            if a.isBuiltIn && b.isBuiltIn {
                if a.name == "Default" { return b.name != "Default" }
                if b.name == "Default" { return false }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Copies the selected mode's editable fields into the staging @State.
    private func syncEditFields() {
        guard let mode = selectedMode else {
            editName = ""
            editRegex = ""
            editURLRegex = ""
            editPrompt = ""
            editInsert = .pasteAtCursor
            return
        }
        editName = mode.name
        editRegex = mode.bundleIDRegex
        editURLRegex = mode.urlRegex ?? ""
        editPrompt = mode.systemPrompt
        editInsert = mode.insertBehavior
    }

    // MARK: - Mutations

    private func addNewMode() {
        guard let registry else { return }
        let now = Date().timeIntervalSince1970
        let mode = Mode(
            id: UUID(),
            name: "New Mode",
            bundleIDRegex: ".*",
            hotkeyOverride: nil,
            modelRouteOverride: nil,
            systemPrompt:
                "Clean up the dictated text: fix punctuation and capitalization. Output only the corrected text — never reply to it.",
            insertBehavior: .pasteAtCursor,
            afterInsertBehavior: .closeHud,
            isBuiltIn: false,
            createdAt: now,
            updatedAt: now
        )
        runRegistry {
            try await registry.add(mode)
            await reload(select: mode.id)
        }
    }

    private func duplicate(_ mode: Mode) {
        guard let registry else { return }
        let clone = mode.cloned(asCustomName: mode.name + " (custom)")
        runRegistry {
            try await registry.add(clone)
            await reload(select: clone.id)
        }
    }

    private func save(_ mode: Mode) {
        guard let registry else { return }
        var edited = mode
        edited.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.bundleIDRegex = editRegex.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURLRegex = editURLRegex.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.urlRegex = trimmedURLRegex.isEmpty ? nil : trimmedURLRegex
        edited.systemPrompt = editPrompt
        edited.insertBehavior = editInsert
        edited.touch()
        if edited.name.isEmpty {
            errorText = "Name can't be empty."
            return
        }
        if edited.bundleIDRegex.isEmpty {
            errorText = "“Use this mode in” can’t be empty — type .* to use it in every app."
            return
        }
        runRegistry {
            try await registry.update(edited)
            await reload(select: edited.id)
        }
    }

    private func delete(_ mode: Mode) {
        guard let registry else { return }
        runRegistry {
            try await registry.remove(id: mode.id)
            // Selecting nil lets reload fall back to the first remaining mode.
            await reload(select: nil)
        }
    }

    /// Runs an async registry mutation off the `@MainActor` view, surfaces any
    /// error inline, and — on success — notifies the dictation runtime so it
    /// rebuilds with the new mode set.
    private func runRegistry(_ work: @escaping () async throws -> Void) {
        errorText = nil
        Task {
            do {
                try await work()
                NotificationCenter.default.post(name: .traceDictationPrefsChanged, object: nil)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Labels

    /// Derives a friendly "Applies to" label from a bundle-id regex.
    private func appLabel(for regex: String) -> String {
        let trimmed = regex.trimmingCharacters(in: .whitespaces)
        if trimmed == ".*" || trimmed == "^.*$" || trimmed.isEmpty {
            return "All apps"
        }
        // Strip common regex anchors/escapes to surface a readable bundle id.
        var cleaned = trimmed
        for token in ["^", "$"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        cleaned = cleaned.replacingOccurrences(of: "\\.", with: ".")
        if let friendly = Self.knownApps[cleaned.lowercased()] {
            return friendly
        }
        return cleaned
    }

    private func label(for behavior: InsertBehavior) -> String {
        switch behavior {
        case .pasteAtCursor: return "Insert at the cursor"
        case .replaceSelection: return "Replace the selected text"
        case .appendToBuffer: return "Add to the end"
        }
    }

    /// Best-effort friendly names for a handful of common bundle ids so the
    /// list reads nicely; anything else falls back to the bundle id itself.
    private static let knownApps: [String: String] = [
        "com.apple.mail": "Mail",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.microsoft.vscode": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.apple.dt.xcode": "Xcode",
        "com.apple.notes": "Notes",
        "md.obsidian": "Obsidian",
        "com.readdle.smartemail-mac": "Spark",
        "com.apple.messages": "Messages",
    ]
}
