import AppKit
import SharedCore
import SwiftUI

/// Settings → Integrations → Watched Folders.
///
/// Configures folders the app
/// auto-transcribes (each new audio/video file is queued, filed into the
/// folder's project) and the opt-in iPhone Voice Memo iCloud sync, including the
/// one-time retroactive-import choice (BAS-22).
@MainActor
public struct WatchedFoldersSettingsView: View {
    @Environment(\.brutalistPalette) private var palette
    var state: AppStateModel?

    @State private var projects: [ProjectInfo] = []
    @State private var showVoiceMemoImportDialog = false
    @State private var voiceMemoBacklogCount = 0

    public init(state: AppStateModel? = nil) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let state {
                watchedFoldersGroup(state: state)
                voiceMemoGroup(state: state)
            } else {
                Text("Watched folders are unavailable.")
                    .font(BrutalistTypography.body)
                    .foregroundStyle(palette.fgMuted.color)
                    .padding(32)
            }
        }
        .task { await loadProjects() }
        .confirmationDialog(
            "Found \(voiceMemoBacklogCount) voice memo\(voiceMemoBacklogCount == 1 ? "" : "s") in iCloud",
            isPresented: $showVoiceMemoImportDialog,
            titleVisibility: .visible
        ) {
            Button("Transcribe these and new ones") { enableVoiceMemoSync(importExisting: true) }
            Button("Only new recordings from now on") { enableVoiceMemoSync(importExisting: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Transcribing everything you’ve already recorded can take a while. New recordings are always picked up once this is on."
            )
        }
    }

    // MARK: Watched folders

    @ViewBuilder
    private func watchedFoldersGroup(state: AppStateModel) -> some View {
        SettingsGroup("Watched folders", tag: state.watchedFolders.isEmpty ? nil : "\(state.watchedFolders.count)") {
            if state.watchedFolders.isEmpty {
                SettingsRow(
                    key: "No folders yet",
                    hint:
                        "Add a folder, and any audio or video you drop into it is transcribed automatically and filed into the project you choose.",
                    showDivider: true
                ) { EmptyView() }
            } else {
                ForEach(Array(state.watchedFolders.enumerated()), id: \.element.displayPath) { idx, folder in
                    folderRow(state: state, index: idx, folder: folder)
                }
            }
            SettingsRow(
                key: "Watch a folder",
                hint: "Choose a folder and Trace will transcribe new recordings that land in it.", showDivider: false
            ) {
                BrutalistButton("Add folder…", kind: .primary) { addFolder(state: state) }
            }
        }
    }

    private func folderRow(state: AppStateModel, index: Int, folder: WatchedFolderConfig) -> some View {
        SettingsRow(
            key: URL(fileURLWithPath: folder.displayPath).lastPathComponent,
            hint: folder.displayPath,
            showDivider: true
        ) {
            HStack(spacing: 10) {
                Picker(
                    "",
                    selection: Binding(
                        get: { folder.projectID ?? "" },
                        set: { newValue in
                            updateFolder(state: state, index: index) {
                                $0.with(projectID: newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )
                ) {
                    Text("Inbox — no project").tag("")
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Button(role: .destructive) {
                    removeFolder(state: state, folder: folder)
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.fgMuted.color)
                .help("Stop watching this folder")
            }
        }
    }

    // MARK: iPhone Voice Memos

    @ViewBuilder
    private func voiceMemoGroup(state: AppStateModel) -> some View {
        SettingsGroup("iPhone Voice Memos", tag: state.voiceMemoSyncEnabled ? "On" : nil) {
            SettingsRow(
                key: "Transcribe your Voice Memos",
                hint:
                    "Trace watches your iCloud Voice Memos and transcribes new recordings. Off by default — your existing recordings are never brought in without asking first.",
                value: state.voiceMemoSyncEnabled ? "On" : "Off",
                showDivider: true
            ) {
                if state.voiceMemoSyncEnabled {
                    BrutalistButton("Turn off", kind: .ghost) { state.voiceMemoSyncEnabled = false }
                } else {
                    BrutalistButton("Enable…", kind: .primary) { promptVoiceMemoImport() }
                }
            }
            SettingsRow(
                key: "iCloud folder",
                hint: FileInbox.defaultVoiceMemosFolder().path,
                showDivider: state.voiceMemoSyncEnabled
            ) { EmptyView() }
            if state.voiceMemoSyncEnabled {
                SettingsRow(
                    key: "Bring in older recordings",
                    hint:
                        "Transcribe memos already in the folder that haven’t been done yet. Ones that are already transcribed are skipped.",
                    showDivider: false
                ) {
                    BrutalistButton("Import now", kind: .ghost) { reimportVoiceMemos(state: state) }
                }
            }
        }
    }

    // MARK: Actions

    private func loadProjects() async {
        guard let store = BootContext.current?.projectStore else { return }
        let records = (try? await store.list()) ?? []
        projects = records.map { ProjectInfo(id: $0.id.uuidString, name: $0.name) }
    }

    private func addFolder(state: AppStateModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !state.watchedFolders.contains(where: { $0.displayPath == url.path }) else { return }
        let bookmark = try? SecurityScopedBookmark.make(from: url)
        let config = WatchedFolderConfig(
            bookmarkData: bookmark?.bookmarkData,
            displayPath: url.path,
            importExistingOnFirstScan: true,
            projectID: nil,
            templateID: nil
        )
        state.watchedFolders.append(config)
    }

    private func removeFolder(state: AppStateModel, folder: WatchedFolderConfig) {
        state.watchedFolders.removeAll { $0.displayPath == folder.displayPath }
    }

    private func updateFolder(
        state: AppStateModel, index: Int,
        _ transform: (WatchedFolderConfig) -> WatchedFolderConfig
    ) {
        guard state.watchedFolders.indices.contains(index) else { return }
        state.watchedFolders[index] = transform(state.watchedFolders[index])
    }

    private func promptVoiceMemoImport() {
        // Enumerating the iCloud Voice Memos folder can be slow (hundreds of
        // synced recordings) — do it off the main thread, then show the dialog.
        let folder = FileInbox.defaultVoiceMemosFolder()
        Task {
            let count = await Task.detached { WatchedFolderScan.currentSupportedFiles(in: folder).count }.value
            voiceMemoBacklogCount = count
            showVoiceMemoImportDialog = true
        }
    }

    private func enableVoiceMemoSync(importExisting: Bool) {
        guard let state else { return }
        state.voiceMemoImportExisting = importExisting
        state.voiceMemoSyncEnabled = true
    }

    /// Force a one-time backlog import without re-toggling sync: flip
    /// importExisting on and re-post the watched-folders-changed signal so the
    /// coordinator restarts the watcher and rescans (DB de-dupe skips memos
    /// already transcribed).
    private func reimportVoiceMemos(state: AppStateModel) {
        state.voiceMemoImportExisting = true
        // Re-assigning the same value still fires didSet → notification.
        state.voiceMemoSyncEnabled = true
    }
}
