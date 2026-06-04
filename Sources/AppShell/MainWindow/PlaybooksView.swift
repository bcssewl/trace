import AppKit
import SharedCore
import SwiftUI

/// Library → Playbooks.
///
/// Attach reference doc folders to a project; index them so
/// the in-meeting Coach can ground its cards on them (RAG). Playbooks are
/// per-project because grounding is meant to be scoped to the work at hand.
@MainActor
struct PlaybooksView: View {
    @Environment(\.brutalistPalette) private var palette
    let model: PlaybooksModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let model {
                    if model.projects.isEmpty {
                        emptyProjects
                    } else {
                        controls(model)
                        folderSection(model)
                    }
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background.color)
        .task { await model?.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Playbooks")
                .font(BrutalistTypography.title)
                .foregroundStyle(palette.fg.color)
            Text("Reference folders the coach grounds on · indexed locally for RAG")
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fgMuted.color)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controls(_ model: PlaybooksModel) -> some View {
        HStack(spacing: 10) {
            Text("Project")
                .font(BrutalistTypography.groupTitle)
                .foregroundStyle(palette.fgMuted.color)
            Menu {
                ForEach(model.projects) { project in
                    Button(project.name) { Task { await model.select(project.id) } }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.selectedProjectName())
                        .font(BrutalistTypography.label)
                        .foregroundStyle(palette.fg.color)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.fgMuted.color)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            BrutalistButton("Add folder…", kind: .ghost) { pickFolder(model) }
            BrutalistButton(model.isIndexing ? "Indexing…" : "Index now", kind: .primary) {
                Task { await model.index() }
            }
            .disabled(model.isIndexing || model.folders.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func folderSection(_ model: PlaybooksModel) -> some View {
        if let status = model.statusLine {
            Text(status)
                .font(BrutalistTypography.caption)
                .foregroundStyle(palette.fgMuted.color)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        if model.folders.isEmpty {
            emptyFolders
        } else {
            VStack(spacing: 0) {
                ForEach(model.folders) { folder in folderRow(folder, model) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func folderRow(_ folder: PlaybookFolder, _ model: PlaybooksModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.isStale ? "exclamationmark.triangle" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(folder.isStale ? palette.primary.color : palette.fgMuted.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.url?.lastPathComponent ?? (folder.path as NSString).lastPathComponent)
                    .font(BrutalistTypography.label)
                    .foregroundStyle(palette.fg.color)
                Text(folderSubtitle(folder))
                    .font(BrutalistTypography.caption)
                    .foregroundStyle(palette.fgMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Task { await model.remove(folder.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.fgMuted.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(
            Rectangle().fill(palette.borderSoft.color).frame(height: BrutalistMetrics.hairline),
            alignment: .bottom
        )
    }

    private func folderSubtitle(_ folder: PlaybookFolder) -> String {
        if folder.isStale { return "Access lost — re-add this folder" }
        let indexed = folder.indexedAt != nil ? "indexed" : "not indexed yet"
        return "\(folder.path) · \(indexed)"
    }

    private var emptyProjects: some View {
        BrutalistEmptyState(
            symbol: "folder.badge.questionmark",
            title: "No projects yet",
            detail:
                "Playbooks attach to a project. Create a project first, then add reference folders here for the coach to ground on."
        )
    }

    private var emptyFolders: some View {
        BrutalistEmptyState(
            symbol: "book",
            title: "No playbooks for \(model?.selectedProjectName() ?? "this project")",
            detail:
                "Add a folder of reference docs (Markdown, text, PDF, or Word). After indexing, the coach surfaces grounded cards quoting them when they're relevant."
        )
    }

    private func pickFolder(_ model: PlaybooksModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of reference docs (Markdown, text, PDF, or Word) for this project's coach."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.add(url) }
        }
    }
}
